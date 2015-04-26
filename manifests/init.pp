# manifests/init.pp - module to manage and deploy restart monkey
class restartmonkey (
  $cmd_args = ""
) {
  file{'/usr/local/sbin/restart-monkey':
    source  => 'puppet:///modules/restartmonkey/restart_monkey.rb',
    owner   => root,
    group   => 0,
    mode    => '0700';
  }

  cron { 'puppet_run_restartmonkey':
    command => "/usr/local/sbin/restart-monkey ${cmd_args}",
    user    => 'root',
    hour    => fqdn_rand(24),
    minute  => fqdn_rand(59),
    require => File['/usr/local/sbin/restart-monkey'];
  }
}
