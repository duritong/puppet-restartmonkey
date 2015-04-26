# manifests/init.pp - module to manage and deploy restart monkey
#
# run_at can be:
#  * never: no cron
#  * hourly: every hour
#  * daily: once a day
#  * weekly: once a week
#  * monthly: once a month
class restartmonkey(
  $run_at  = 'daily',
  $dry_run = false,
  $verbose = false,
) {

  $dry_run_str = $dry_run ? {
    true    => ' --dry-run',
    default => ''
  }
  $verbose_str = $verbose ? {
    true    => ' --verbose',
    default => ''
  }

  file{
    '/usr/local/sbin/restart-monkey':
      source  => 'puppet:///modules/restartmonkey/restart_monkey.rb',
      owner   => root,
      group   => 0,
      mode    => '0700';
    '/etc/cron.d/run_restartmonkey':
      require => File['/usr/local/sbin/restart-monkey'];
  }
  if $run_at != 'never' {
    $minute_str = fqdn_rand(59)
    if $run_at == 'hourly' {
      $cron_str = "${minute_str} * * * *"
    } else {
      $hour_str = fqdn_rand(24)
      if $run_at == 'daily' {
        $cron_str = "${minute_str} ${hour_str} * * *"
      } else {
        if $run_at == 'weekly' {
          $weekday = fqdn_rand(7)
          $cron_str = "${minute_str} ${hour_str} * * ${weekday}"
        } elsif $run_at == 'monthly' {
          $day_month = fqdn_rand(29)
          $cron_str = "${minute_str} ${hour_str} ${day_month} * *"
        } else {
          fail("No such run_at value (${run_at}) supported")
        }
      }
    }

    File['/etc/cron.d/run_restartmonkey']{
      content => "${cron_str} * * * root \
/usr/local/sbin/restart-monkey${dry_run_str}${verbose_str}\n",
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
