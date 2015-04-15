#!/usr/bin/env ruby

DEBUG = ARGV.include?('--debug')

SYSTEMCTL = `which systemctl 2> /dev/null`

DRY_RUN = ARGV.include?('--dry-run')

if DRY_RUN
  puts "--- Restartmonkey dry-run"
end

# copy from shellwords.rb
def shellescape(str)
  str = str.to_s

  # An empty argument will be skipped, so return empty quotes.
  return "''" if str.empty?

  str = str.dup

  # Treat multibyte characters as is.  It is caller's responsibility
  # to encode the string in the right encoding for the shell
  # environment.
  str.gsub!(/([^A-Za-z0-9_\-.,:\/@\n])/, "\\\\\\1")

  # A LF cannot be escaped with a backslash because a backslash + LF
  # combo is regarded as line continuation and simply ignored.
  str.gsub(/\n/, "'\n'")
end

def longest_common_substr(strings)
  shortest = strings.min_by &:length
  maxlen = shortest.length
  maxlen.downto(0) do |len|
    0.upto(maxlen - len) do |start|
      substr = shortest[start,len]
      return substr if strings.all?{|str| str.include? substr }
    end
  end
end

SERVICES =
  unless SYSTEMCTL.empty?
    ss = `systemctl list-units | awk '{print $1}' | head -n -2`
    ss.split("\n").collect do |s|
      s =~ /(.*).service$/
      $1
    end.compact
  else
    `ls -l /etc/init.d/ | awk '{print $9}'`.split("\n")
  end.collect do |s|
    shellescape(s)
  end

def pids
  `cd /proc && ls [0-9]* -ld 2> /dev/null | awk '{print $9}'`.split("\n")
end

def libraries(pids)
  libs = {}

  pids.each do |p|
    # make sure its a number
    pid = p.to_i
    ls = `cat /proc/#{pid}/smaps 2> /dev/null | grep 'lib' | awk '{print $6}'`
    ls.split("\n").uniq.each do |lib|
      libs[lib] ||= []
      libs[lib] << pid
    end
  end

  libs
end

def vanished_libraries(libs)
  libs.select do |lib|
    ! File.exist? lib
  end
end

def affected_exes(vanished_libs, updated_pids)
  affected_pids = (vanished_libs.values.flatten + updated_pids).uniq
  affected_pids.collect do |p|
    pid = p.to_i
    `readlink /proc/#{pid}/exe`.gsub(" (deleted)", "")
  end.uniq.sort
end

def updated_pids(pids)
  pids.select do |p|
    pid = p.to_i
    `readlink /proc/#{pid}/exe` =~ / \(deleted\)$/
  end.uniq.sort
end


def guess_affected_services(affected_exes)
  ignored_names = /daemon|service|common|finish|dispatcher|system|\.sh|boot|setup|support/

  as = affected_exes.collect do |exe|
    SERVICES.select do |service|
      s = service.gsub(ignored_names, "")
      e = File.basename(exe)
      c = longest_common_substr([e, s])
      c.length > 3
    end
  end.flatten.uniq.sort

  if DEBUG
    unless as.empty?
      puts "Probably affected Services:"
      as.each do |service|
        puts "* #{service}"
      end
    end
  end

  as
end


def find_affected_exes
  libs          = libraries(pids)
  vanished_libs = vanished_libraries(libs)
  updated       = updated_pids(pids)
  exes          = affected_exes(vanished_libs, updated)

  if DEBUG
    unless vanished_libs.empty?
      puts "Updated Libraries:"
      vanished_libs.keys.sort.each do |lib|
        l = File.basename(lib)
        puts "* #{l}"
      end
    end
    unless exes.empty?
      puts "Affected Exes:"
      exes.each do |exe|
        puts "* #{exe}"
      end
    end
  end

  [exes, vanished_libs]
end

def restart(names)
  blacklist = ["halt", "reboot", "libvirt-guests", "cryptdisks",
               "functions", "qemu-kvm", "rc"]

  names.each do |name|
    next if blacklist.include? name
    next unless SERVICES.include? name

    cmd = unless SYSTEMCTL.empty?
      "systemctl restart #{name}"
    else
      "/etc/init.d/#{name} restart"
    end
    if DRY_RUN
      puts "Would exec: '#{cmd}'"
    else
      `#{cmd}`
    end
  end
end

affected = find_affected_exes.shift

if affected.size > 0
  to_restart = guess_affected_services(affected)

  restart(to_restart)

  unless DRY_RUN
    still_affected = find_affected_exes

    if still_affected[0].size > 0
      puts "Unable to Resolve Proplems with the following prcesses:"
      still_affected = find_affected_exes
      still_affected[0].each do |a|
        puts "* #{a}"
      end
      puts "Affected libraries:"
      still_affected[1].keys.each do |a|
        puts "* #{a}"
      end
    end
  end
end


