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
  $wc_nc = fqdn_rand(2) + 1
  $wc_de = fqdn_rand(4) + 1
  $wait_count = $policy ? {
    'canary'     => 0,
    'non-canary' => $wc_nc,
    'delicate'   => $wc_de,
    default      => fqdn_rand(2),
  }
  $wait_str = " --wait-count ${wait_count}"

  file{
    '/usr/local/sbin/restart-monkey':
      source  => 'puppet:///modules/restartmonkey/restart_monkey.rb',
      owner   => root,
      group   => 0,
      mode    => '0700';
    '/etc/restartmonkey.conf':
      content => inline_template("---\nwhitelist:<%= @whitelist.empty? ? ' []' : \"\n  - #{@whitelist.sort.join(\"\n  - \")}\" %>\nignore:<%= @ignore.empty? ? ' []' : \"\n  - #{@ignore.sort.join(\"\n  - \")}\" %>\n"),
      owner   => root,
      group   => 0,
      mode    => '0600';
    '/etc/cron.d/run_restartmonkey':
      require => File['/usr/local/sbin/restart-monkey'];
    '/etc/cron.monthly/restartmonkey_info':
      require => File['/usr/local/sbin/restart-monkey'];
  }
  if $active {
    $minute_str = fqdn_rand(59)
    # generate an hour within the night
    $rand_hour = fqdn_rand(10)
    $hour_str = (31 - $rand_hour) % 24

    # run it one a month in verbose to inform about remaining problems
    File['/etc/cron.monthly/restartmonkey_info']{
      content => '/usr/local/sbin/restart-monkey --cron --dry-run --verbose',
      owner   => 'root',
      group   => 0,
      mode    => '0744',
    }
    File['/etc/cron.d/run_restartmonkey']{
      content => "${minute_str} ${hour_str} * * * root \
/usr/local/sbin/restart-monkey --cron${dry_run_str}${verbose_str}${wait_str}\n",
      owner   => 'root',
      group   => 0,
      mode    => '0644',
    }
  } else {
    File['/etc/cron.d/run_restartmonkey',
      '/etc/cron.monthly/restartmonkey_info']{
      ensure => 'absent',
    }
  }
}
