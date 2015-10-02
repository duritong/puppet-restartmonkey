#!/usr/bin/env ruby

require 'yaml'
require 'optparse'
require 'fileutils'

OPTION = {}
OptionParser.new do |opts|
  opts.banner = "Usage: restartmonkey [options]"
  opts.on("-v", "--verbose", "Run verbosely") do |v|
    OPTION[:verbose] = v
  end
  opts.on("-d", "--dry-run", "Don't do anything for real") do |v|
    OPTION[:dry_run] = v
  end
  opts.on("-c", "--cron", "Only report errors and warnings, overwritten by verbose or debug") do |c|
    OPTION[:cron] = c
  end
  opts.on("-w", "--wait-count [n]", Integer,
          "Schedule service restart after n runs.") do |w|
    OPTION[:wait_count] = w
  end
  opts.on("--debug", "Print debug information") do |v|
    OPTION[:debug]   = v
    OPTION[:verbose] = v
  end
end.parse!

SYSTEMCTL = `which systemctl 2> /dev/null`

class Log
  class << self
    def info(msg)
      STDOUT.puts "INFO: #{msg}" if OPTION[:verbose]
    end
    def debug(msg)
      STDOUT.puts "DEBUG: #{msg}" if OPTION[:debug]
    end
    def puts(msg)
     STDOUT.puts msg if (!OPTION[:cron] || OPTION[:verbose] || OPTION[:debug])
    end
    def warn(msg)
      STDOUT.puts "WARNING: #{msg}"
    end
    def error(msg)
      STDERR.puts "ERROR: #{msg}"
    end
  end
end

if Process.uid != 0
  if OPTION[:dry_run]
    Log.warn("not running as root. Not all processes shown")
  else
    raise 'Must run as root'
  end
end

CONFIG_FILE = "/etc/restartmonkey.conf"
SPOOL_PATH  = "/var/spool/restartmonkey"
SPOOL_FILE  = File::join(SPOOL_PATH, "jobs")

class Cnf
  def initialize
    @cnf = YAML::load_file(CONFIG_FILE) rescue {}
  end

  def whitelisted?(service)
    (@cnf["whitelist"] || []).include? service
  end

  def ignored?(service)
    (@cnf["ignore"] || []).include? service
  end
end
CONFIG = Cnf.new

class Jobs
  def initialize
    @jobs = (YAML::load_file(SPOOL_FILE) rescue {}) || {}
    @new_jobs = {}
  end

  def write
    FileUtils.mkdir_p(SPOOL_PATH)
    FileUtils.chmod_R(0600, SPOOL_PATH)
    File.open(SPOOL_FILE, 'w') {|f| f.write @new_jobs.to_yaml }
  end

  def schedule(name)
    wait_count = Integer(@jobs[name] || OPTION[:wait_count] || 0)
    if wait_count == 0
      if OPTION[:dry_run]
        Log.puts "Would restart service '#{name}'"
      else
        do_restart(name)
        sleep(1)
        unless check_service(name)
          do_start(name)
        end
      end
    else
      if OPTION[:dry_run]
        Log.puts "Would schedule service '#{name}' to be restarted in #{wait_count} runs"
      else
        Log.puts "Probably affected service '#{name}' is scheduled to be restarted in #{wait_count} runs"
        @new_jobs[name] = wait_count - 1
      end
    end
  end
end
JOBS = Jobs.new

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
  shortest = strings.min_by(&:length)
  maxlen = shortest.length
  maxlen.downto(0) do |len|
    0.upto(maxlen - len) do |start|
      substr = shortest[start,len]
      return substr if strings.all?{|str| str.include? substr }
    end
  end
end

def exec_cmd(cmd, force=!OPTION[:dry_run])
  if force
    Log.debug "Run: #{cmd}"
    output = `#{cmd}`
    res = $?
  else
    Log.puts "Would run: #{cmd}"
    output = ''
    res = 0
  end
  if OPTION[:debug]
    Log.debug "Output: #{output}"
  end
  res.to_i == 0
end

unless SYSTEMCTL.empty?
  ss = `systemctl list-units | awk '{print $1}' | head -n -2`
  SERVICES = ss.split("\n").collect do |s|
    s =~ /(.*).service$/
    shellescape($1)
  end.compact

  def do_restart(service)
    unless exec_cmd("systemctl restart #{service}")
      Log.error "Failed to restart '#{service}'"
    end
  end
  def do_start(service)
    unless exec_cmd("systemctl start #{service}")
      Log.error "Failed to start '#{service}'"
    end
  end
  def check_service(service)
    exec_cmd("systemctl is-active #{service}", true)
  end
else
  SERVICES = `ls -l /etc/init.d/ | awk '{print $9}'`.split("\n").collect do |s|
    shellescape(s)
  end
  def do_restart(service)
    unless exec_cmd("/etc/init.d/#{service} restart")
      Log.error "Failed to restart '#{service}'"
    end
  end
  def do_start(service)
    unless exec_cmd("/etc/init.d/#{service} start")
      Log.error "Failed to start '#{service}'"
    end
  end
  def check_service(service)
    exec_cmd("/etc/init.d/#{service} status",true)
  end
end

def pids
  @pids ||= Dir['/proc/[0-9]*'].collect{|d| File.basename(d) }
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
  Hash[libs.collect do |lib, pid|
    if File.exist?(lib) then nil else [lib, pid] end
  end.compact]
end

def cmdline(pid)
  `cat /proc/#{pid}/cmdline | xargs -0 echo`.chomp
end

def is_interpreter?(exe)
  exe =~ /#{interpreter_regexp}(;.*)?$/
end

def interpreter_regexp
  'bin\/(perl|ruby|python)[\d\.]*'
end

def affected_exes(affected_pids)
  Hash[affected_pids.collect do |p|
    pid = p.to_i
    exe = `readlink /proc/#{pid}/exe`.gsub(" (deleted)", "").chomp
    if is_interpreter?(exe)
      exe = cmdline(pid).sub(/.*#{interpreter_regexp}[\-\w\s]*\//,'/').gsub(/\s.*$/,'')
    end
    [pid, exe]
  end.uniq.sort]
end

def updated_pids(pids)
  pids.select do |p|
    pid = p.to_i
    `readlink /proc/#{pid}/exe` =~ / \(deleted\)$/
  end.uniq.sort
end


def guess_affected_services(affected_exes)
  ignored_names = /daemon|service|common|finish|dispatcher|system|\.sh|boot|setup|support/
  service_mapping = {
    "mysqld" => "mariadb",
  }

  as = affected_exes.collect do |exe|
    SERVICES.select do |service|
      s = service.gsub(ignored_names, "")
      e = File.basename(exe)
      c = longest_common_substr([e, s])
      if service_mapping[e]
        c2 = longest_common_substr([service_mapping[e], s])
        c = [c,c2].max
      end
      c.length > 3
    end
  end.flatten.uniq.sort

  as_todo = as.select{|s| check_service(s) }

  skip_as = as - as_todo

  unless as_todo.empty?
    Log.info "Probably affected services:"
    as_todo.each do |service|
      Log.info "* #{service}"
    end
  end
  unless skip_as.empty?
    Log.info "Ignoring non-running services:"
    skip_as.each do |service|
      Log.info "* #{service}"
    end
  end

  as_todo
end

def print_affected(exes, libs)
  unless (libs.empty? && exes.empty?)
    Log.puts "\nCurrently the following problems persist:"
  end
  unless libs.empty?
    Log.puts "Updated Libraries:"
    libs.keys.sort.each do |lib|
      l = File.basename(lib)
      Log.puts "* #{l}"
    end
  end
  unless exes.empty?
    Log.puts "Affected Exes:"
    exes.each do |pid, exe|
      Log.puts "* #{exe} [#{pid}] (#{`cat /proc/#{pid}/cmdline | xargs -0 echo`.chomp})"
    end
  end
end

def find_affected_exes(verbose = false)
  libs          = libraries(pids)
  vanished_libs = vanished_libraries(libs)
  updated       = updated_pids(pids)
  affected_pids = (vanished_libs.values.flatten + updated).uniq
  exes          = affected_exes(affected_pids)

  print_affected(exes, vanished_libs) if verbose

  exes.values
end

def restart(names)
  blacklist = ["halt", "reboot", "libvirt-guests", "cryptdisks",
               "functions", "qemu-kvm", "rc", "network", "networking",
               "killprocs", "mountall", "sendsigs"]

  names.each do |name|
    name = name.split("@")[0]

    next if blacklist.include? name
    next unless SERVICES.include? name

    if CONFIG.ignored? name
      Log.debug "Skipping ignored service '#{name}'"
      next
    end

    if CONFIG.whitelisted? name
      JOBS.schedule(name)
    else
      Log.puts "Skipping restart of probably affected service '#{name}' since it's not whitelisted"
    end
  end
end

affected = find_affected_exes

if affected.size > 0
  to_restart = guess_affected_services(affected)

  restart(to_restart)

  find_affected_exes(true)
end

JOBS.write unless OPTION[:dry_run]
