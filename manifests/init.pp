# manifests/init.pp - module to manage and deploy restart monkey
class restartmonkey(
  $active  = true,
  $dry_run = false,
  $verbose = false,
  $policy  = 'normal',
  $whitelist = [],
  $ignore    = [],
) {

  $dry_run_str = $dry_run ? {
    true    => ' --dry-run',
    default => ''
  }
  $verbose_str = $verbose ? {
    true    => ' --verbose',
    default => ''
  }
  $wait_str = $policy ? {
    'canary'   => ' --wait-count 0',
    'delicate' => ' --wait-count 3',
    default    => ' --wait-count 1',
  }

  file{
    '/usr/local/sbin/restart-monkey':
      source  => 'puppet:///modules/restartmonkey/restart_monkey.rb',
      owner   => root,
      group   => 0,
      mode    => '0700';
    '/etc/restartmonkey.conf':
      content => inline_template("<%= { 'whitelist' => @whitelist, 'ignore' => @ignore }.to_yaml %>"),
      owner   => root,
      group   => 0,
      mode    => '0600';
    '/etc/cron.d/run_restartmonkey':
      require => File['/usr/local/sbin/restart-monkey'];
  }
  if $active {
    $minute_str = fqdn_rand(59)
    # generate an hour within the night
    $rand_hour = fqdn_rand(10)
    $hour_str = (31 - $rand_hour) % 24

    File['/etc/cron.d/run_restartmonkey']{
      content => "${minute_str} ${hour_str} * * * root \
/usr/local/sbin/restart-monkey${dry_run_str}${verbose_str}${$wait_str}\n",
      owner   => 'root',
      group   => 0,
      mode    => '0644',
    }
  } else {
    File['/etc/cron.d/run_restartmonkey']{
      ensure => 'absent',
    }
  }
}
