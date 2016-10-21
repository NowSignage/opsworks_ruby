# frozen_string_literal: true

prepare_recipe

include_recipe 'opsworks_ruby::configure'

# rubocop:disable Metrics/BlockLength
every_enabled_application do |application, deploy|
  databases = []
  every_enabled_rds(self, application) do |rds|
    databases.push(Drivers::Db::Factory.build(self, application, rds: rds))
  end

  scm = Drivers::Scm::Factory.build(self, application)
  framework = Drivers::Framework::Factory.build(self, application, databases: databases)
  appserver = Drivers::Appserver::Factory.build(self, application)
  worker = Drivers::Worker::Factory.build(self, application, databases: databases)
  webserver = Drivers::Webserver::Factory.build(self, application)
  bundle_env = scm.class.adapter.to_s == 'Chef::Provider::Git' ? { 'GIT_SSH' => scm.out[:ssh_wrapper] } : {}

  fire_hook(:before_deploy, items: databases + [scm, framework, appserver, worker, webserver])

  deploy application['shortname'] do
    deploy_to deploy_dir(application)
    user node['deployer']['user'] || 'root'
    group www_group
    rollback_on_error true
    environment application['environment'].merge(framework.out[:deploy_environment] || {})

    keep_releases deploy[:keep_releases]
    create_dirs_before_symlink(
      (node['defaults']['deploy']['create_dirs_before_symlink'] + Array.wrap(deploy[:create_dirs_before_symlink])).uniq
    )
    purge_before_symlink(
      (node['defaults']['deploy']['purge_before_symlink'] + Array.wrap(deploy[:purge_before_symlink])).uniq
    )
    symlink_before_migrate deploy[:symlink_before_migrate]
    symlinks(node['defaults']['deploy']['symlinks'].merge(deploy[:symlinks] || {}))

    scm.out.each do |scm_key, scm_value|
      send(scm_key, scm_value) if respond_to?(scm_key)
    end

    [appserver, webserver].each do |server|
      server.notifies[:deploy].each do |config|
        notifies config[:action],
                 config[:resource].respond_to?(:call) ? config[:resource].call(application) : config[:resource],
                 config[:timer]
      end
    end

    migration_command(framework.out[:migration_command]) if framework.out[:migration_command]
    migrate framework.out[:migrate]
    before_migrate do
      perform_bundle_install(shared_path, bundle_env)

      fire_hook(:deploy_before_migrate, items: databases + [scm, framework, appserver, worker, webserver])

      run_callback_from_file(File.join(release_path, 'deploy', 'before_migrate.rb'))
    end

    before_symlink do
      perform_bundle_install(shared_path, bundle_env) unless framework.out[:migrate]

      fire_hook(:deploy_before_symlink, items: databases + [scm, framework, appserver, worker, webserver])

      run_callback_from_file(File.join(release_path, 'deploy', 'before_symlink.rb'))
    end

    before_restart do
      directory File.join(release_path, '.git') do
        recursive true
        action :delete
      end if scm.out[:remove_scm_files]

      fire_hook(:deploy_before_restart, items: databases + [scm, framework, appserver, worker, webserver])

      run_callback_from_file(File.join(release_path, 'deploy', 'before_restart.rb'))
    end

    after_restart do
      fire_hook(:deploy_after_restart, items: databases + [scm, framework, appserver, worker, webserver])

      run_callback_from_file(File.join(release_path, 'deploy', 'after_restart.rb'))
    end
  end

  fire_hook(:after_deploy, items: databases + [scm, framework, appserver, worker, webserver])
end
# rubocop:enable Metrics/BlockLength
