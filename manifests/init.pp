# manifests/init.pp - module to manage and deploy restart monkey

file{'/usr/local/bin/restart-monkey':
  source  => "puppet:///modules/restartmonkey/restart_monkey.rb",
  owner   => root,
  group   => 0,
  mode    => '0700';
}
