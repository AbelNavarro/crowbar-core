SimpleNavigation::Configuration.run do |navigation|  
  navigation.items do |primary|
    primary.item :dashboard, t('nav.nodes'), root_path do |secondary|
      secondary.item :dashboard, t('nav.dashboard'), root_path
      secondary.item :dashboard, t('nav.list'), nodes_list_path
    end
    primary.item :barclamps, 'NEW-'+t('nav.barclamps'), barclamp_modules_path do |secondary|
      # barclamps can add menu items here
    end
    primary.item :barclamps, t('nav.barclamps'), barclamp_index_barclamp_path
    primary.item :proposals, t('nav.proposals'), barclamp_proposals_barclamp_path
    primary.item :roles, t('nav.roles'), barclamp_roles_barclamp_path
    primary.item :help, t('nav.help'), '/users_guide.pdf', { :link => { :target => "_blank" } }
  end
end
