#
# Copyright 2016, SUSE LINUX GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "open3"

module Api
  class Upgrade < Tableless
    class << self
      def status
        ::Crowbar::UpgradeStatus.new.progress
      end

      def checks
        {}.tap do |ret|
          ret[:network_checks] = {
            required: true,
            passed: network_checks.empty?,
            errors: sanity_check_errors
          }
          ret[:maintenance_updates_installed] = {
            required: true,
            passed: maintenance_updates_status.empty?,
            errors: maintenance_updates_check_errors
          }
          ret[:compute_resources_available] = {
            required: false,
            passed: compute_resources_available?,
            errors: compute_resources_check_errors
          }
          ret[:ceph_healthy] = {
            required: true,
            passed: ceph_healthy?,
            errors: ceph_health_check_errors
          } if Api::Crowbar.addons.include?("ceph")
          ret[:ha_configured] = {
            required: false,
            passed: ha_present?,
            errors: ha_presence_errors
          }
          ret[:clusters_healthy] = {
            required: true,
            passed: clusters_healthy?,
            errors: clusters_health_report_errors
          } if Api::Crowbar.addons.include?("ha")
        end
      end

      def best_method
        checks_cached = checks
        return "none" if checks_cached.any? do |_id, c|
          c[:required] && !c[:passed]
        end
        return "non-disruptive" unless checks_cached.any? do |_id, c|
          (c[:required] || !c[:required]) && !c[:passed]
        end
        return "disruptive" unless checks_cached.any? do |_id, c|
          (c[:required] && !c[:passed]) && (!c[:required] && c[:passed])
        end
      end

      def noderepocheck
        response = {}
        addons = Api::Crowbar.addons
        addons.push("os", "openstack").each do |addon|
          response.merge!(Api::Node.repocheck(addon: addon))
        end
        response
      end

      def adminrepocheck
        # FIXME: once we start working on 7 to 8 upgrade we have to adapt the sles version
        zypper_stream = Hash.from_xml(
          `sudo /usr/bin/zypper-retry --xmlout products`
        )["stream"]

        {}.tap do |ret|
          if zypper_stream["message"] =~ /^System management is locked/
            return {
              status: :service_unavailable,
              error: I18n.t(
                "api.crowbar.zypper_locked", zypper_locked_message: zypper_stream["message"]
              )
            }
          end

          unless zypper_stream["prompt"].nil?
            return {
              status: :service_unavailable,
              error: I18n.t(
                "api.crowbar.zypper_prompt", zypper_prompt_text: zypper_stream["prompt"]["text"]
              )
            }
          end

          products = zypper_stream["product_list"]["product"]

          os_available = repo_version_available?(products, "SLES", "12.3")
          ret[:os] = {
            available: os_available,
            repos: {}
          }
          ret[:os][:repos][admin_architecture.to_sym] = {
            missing: ["SUSE Linux Enterprise Server 12 SP3"]
          } unless os_available

          cloud_available = repo_version_available?(products, "suse-openstack-cloud", "8")
          ret[:openstack] = {
            available: cloud_available,
            repos: {}
          }
          ret[:openstack][:repos][admin_architecture.to_sym] = {
            missing: ["SUSE OpenStack Cloud 8"]
          } unless cloud_available
        end
      end

      def target_platform(options = {})
        platform_exception = options.fetch(:platform_exception, nil)

        case ENV["CROWBAR_VERSION"]
        when "4.0"
          if platform_exception == :ceph
            ::Crowbar::Product.ses_platform
          else
            NodeObject.admin_node.target_platform
          end
        end
      end

      # Shutdown non-essential services on all nodes.
      def services
        begin
          # prepare the scripts for various actions necessary for the upgrade
          service_object = CrowbarService.new(Rails.logger)
          service_object.prepare_nodes_for_os_upgrade
        rescue => e
          msg = e.message
          Rails.logger.error msg
          return {
            status: :unprocessable_entity,
            message: msg
          }
        end

        # Initiate the services shutdown by calling scripts on all nodes.
        # For each cluster, it is enough to initiate the shutdown from one node (e.g. founder)
        NodeObject.find("state:crowbar_upgrade AND pacemaker_founder:true").each do |node|
          node.ssh_cmd("/usr/sbin/crowbar-shutdown-services-before-upgrade.sh")
        end
        # Shutdown the services for non clustered nodes
        NodeObject.find("state:crowbar_upgrade AND NOT run_list_map:pacemaker-cluster-member").
          each do |node|
          node.ssh_cmd("/usr/sbin/crowbar-shutdown-services-before-upgrade.sh")
        end

        {
          status: :ok,
          message: ""
        }
      end

      def cancel
        service_object = CrowbarService.new(Rails.logger)
        service_object.revert_nodes_from_crowbar_upgrade

        {
          status: :ok,
          message: ""
        }
      rescue => e
        Rails.logger.error(e.message)

        {
          status: :unprocessable_entity,
          message: e.message
        }
      end

      # Orchestrate the upgrade of the nodes
      def nodes
        # check for current global status
        # 1. TODO: return if upgrade has finished
        # 2. TODO: find the next big step
        next_step = "controllers"

        if next_step == "controllers"

          # TODO: Save the "current_step" to global status
          if upgrade_controller_nodes
            # upgrading controller nodes succeeded, we can continue with computes
            next_step = "computes"
          else
            # upgrading controller nodes has failed, exiting
            # leaving next_step as "controllers", so we continue from correct point on retry
            return false
          end
        end

        if next_step == "computes"
          # TODO: Save the "current_step" to global status
          upgrade_compute_nodes
        end
        true
      end

      protected

      def upgrade_controller_nodes
        drbd_nodes = NodeObject.find("drbd:*")
        # FIXME: prepare for cases with no drbd out there
        return true if drbd_nodes.empty?

        # TODO: find the controller node that needs to be upgraded now
        # First node to upgrade is DRBD slave
        drbd_slave = ""
        drbd_master = ""
        NodeObject.find(
          "state:crowbar_upgrade AND (roles:database-server OR roles:rabbitmq-server)"
        ).each do |db_node|
          cmd = "LANG=C crm resource status ms-drbd-{postgresql,rabbitmq}\
          | grep \\$(hostname) | grep -q Master"
          out = db_node.run_ssh_cmd(cmd)
          if out[:exit_code].zero?
            drbd_master = db_node.name
          else
            drbd_slave = db_node.name
          end
        end
        return false if drbd_slave.empty?

        node_api = Api::Node.new drbd_slave

        save_upgrade_state("Starting the upgrade of node #{drbd_slave}")
        return false unless node_api.upgrade

        # Explicitly mark node1 as the cluster founder
        # and adapt DRBD config to the new founder situation.
        # This shoudl be one time action only (for each cluster).
        unless Api::Pacemaker.set_node_as_founder drbd_slave
          save_error_state("Changing the cluster founder to #{drbd_slave} has failed")
          return false
        end

        # Remove "pre-upgrade" attribute from node1
        # We must do it from a node where pacemaker is running
        master_node_api = Api::Node.new drbd_master
        return false unless master_node_api.disable_pre_upgrade_attribute_for drbd_slave

        # FIXME: this should be one time action only (for each cluster)
        return false unless delete_pacemaker_resources drbd_master

        # Execute post-upgrade actions after the node has been upgraded, rebooted
        # and the existing cluster has been cleaned up by deleting most of resources
        return false unless node_api.post_upgrade

        # FIXME: if upgrade went well, continue with next node(s)
        true
      end

      # Delete existing pacemaker resources, from other node in the cluster
      def delete_pacemaker_resources(node_name)
        node = NodeObject.find_node_by_name node_name
        return false if node.nil?

        begin
          node.wait_for_script_to_finish(
            "/usr/sbin/crowbar-delete-pacemaker-resources.sh", 300
          )
          save_upgrade_state("Deleting pacemaker resources was successful.")
        rescue StandardError => e
          save_error_state(
            e.message +
            "Check /var/log/crowbar/node-upgrade.log for details."
          )
          return false
        end
      end

      def save_upgrade_state(message = "")
        # FIXME: update the global status
        Rails.logger.info(message)
      end

      def save_error_state(message = "")
        # FIXME: save the error to global status
        Rails.logger.error(message)
      end

      def upgrade_compute_nodes
        # TODO: not implemented
        true
      end

      def crowbar_upgrade_status
        Api::Crowbar.upgrade
      end

      def maintenance_updates_status
        @maintenance_updates_status ||= ::Crowbar::Checks::Maintenance.updates_status
      end

      def network_checks
        @network_checks ||= ::Crowbar::Sanity.check
      end

      def ceph_status
        @ceph_status ||= Api::Crowbar.ceph_status
      end

      def ceph_healthy?
        ceph_status.empty?
      end

      def ha_presence_status
        @ha_presence_status ||= Api::Pacemaker.ha_presence_check
      end

      def ha_present?
        ha_presence_status.empty?
      end

      def clusters_health_report
        @clusters_health_report ||= Api::Pacemaker.health_report
      end

      def clusters_healthy?
        clusters_health_report.empty?
      end

      def compute_resources_status
        @compute_resounrces_status ||= Api::Crowbar.compute_resources_status
      end

      def compute_resources_available?
        compute_resources_status.empty?
      end

      # Check Errors
      # all of the below errors return a hash with the following schema:
      # code: {
      #   data: ... whatever data type ...,
      #   help: String # "this is how you might fix the error"
      # }
      def sanity_check_errors
        return {} if network_checks.empty?

        {
          network_checks: {
            data: network_checks,
            help: I18n.t("api.upgrade.prechecks.network_checks.help.default")
          }
        }
      end

      def maintenance_updates_check_errors
        return {} if maintenance_updates_status.empty?

        {
          maintenance_updates_installed: {
            data: maintenance_updates_status[:errors],
            help: I18n.t("api.upgrade.prechecks.maintenance_updates_check.help.default")
          }
        }
      end

      def ceph_health_check_errors
        return {} if ceph_healthy?

        {
          ceph_health: {
            data: ceph_status[:errors],
            help: I18n.t("api.upgrade.prechecks.ceph_health_check.help.default")
          }
        }
      end

      def ha_presence_errors
        return {} if ha_present?

        {
          ha_configured: {
            data: ha_presence_status[:errors],
            help: I18n.t("api.upgrade.prechecks.ha_configured.help.default")
          }
        }
      end

      def clusters_health_report_errors
        ret = {}
        return ret if clusters_healthy?

        crm_failures = clusters_health_report["crm_failures"]
        failed_actions = clusters_health_report["failed_actions"]
        ret[:clusters_health_crm_failures] = {
          data: crm_failures.values,
          help: I18n.t(
            "api.upgrade.prechecks.clusters_health.crm_failures",
            nodes: crm_failures.join(",")
          )
        } if crm_failures
        ret[:clusters_health_failed_actions] = {
          data: failed_actions.values,
          help: I18n.t(
            "api.upgrade.prechecks.clusters_health.failed_actions",
            nodes: failed_actions.keys.join(",")
          )
        } if failed_actions
        ret
      end

      def compute_resources_check_errors
        return {} if compute_resources_available?

        {
          compute_resources: {
            data: compute_resources_status[:errors],
            help: I18n.t("api.upgrade.prechecks.compute_resources_check.help.default")
          }
        }
      end

      def repo_version_available?(products, product, version)
        products.any? do |p|
          p["version"] == version && p["name"] == product
        end
      end

      def admin_architecture
        NodeObject.admin_node.architecture
      end
    end
  end
end
