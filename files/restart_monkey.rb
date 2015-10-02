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


class ServiceManager
  def services
    @services ||= find_services
  end
  def do_restart(service)
    raise 'implement for the specific init system'
  end
  def do_start(service)
    raise 'implement for the specific init system'
  end
  def check_service(service)
    raise 'implement for the specific init system'
  end
  def get_service_paths
    raise 'implement for the specific init system'
  end
  def service_suffix
    ''
  end
  def expand_services(services)
    services.collect{|s|expand_service(s) }
  end
  def expand_service(service)
    service
  end
  private
  def find_services
    raise 'implement for the specific init system'
  end
end

class SystemdServiceManager < ServiceManager
  def do_restart(service)
    unless exec_cmd("systemctl reload-or-restart #{service}")
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
  def get_service_paths
    ['/usr/lib/systemd/system','/etc/rc.d/init.d','/etc/init.d']
  end
  def service_suffix
    '.service'
  end
  def expand_service(service)
    if service =~ /@$/
      self.services.select{|s| s.start_with?(service) && check_service(s) }
    else
      super(service)
    end
  end
  private
  def find_services
    `systemctl list-units | grep ' running ' | awk '{print $1}'`.split("\n").collect do |s|
      s =~ /(.*).service$/
      shellescape($1)
    end.compact
  end
end

class InitVServiceManager < ServiceManager
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

  def get_service_paths
    ['/etc/rc.d/init.d', '/etc/init.d']
  end

  private
  def find_services
    Dir['/etc/init.d/*'].collect do |s|
      shellescape(s)
    end
  end
end

SRV_MANAGER = if File.exists?('/usr/bin/systemctl')
  SystemdServiceManager.new
else
  InitVServiceManager.new
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
        SRV_MANAGER.do_restart(name)
        sleep(1)
        unless SRV_MANAGER.check_service(name)
          SRV_MANAGER.do_start(name)
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
  'bin\/(bash|perl|ruby|python)[\d\.]*'
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

class ServiceGuesser
  attr_reader :ignored_names, :service_mapping

  def initialize
    @ignored_names = /daemon|service|common|finish|dispatcher|system|\.sh|boot|setup|support/
    @service_mapping = {
      "mysqld" => "mariadb",
    }
  end

  def guess_affected_services(affected_exes)
    filter_services(affected_exes.collect{|exe| get_affected_service(exe) }.flatten.uniq.sort)
  end
  protected
  def get_affected_service(affected_exe)
    get_service_by_package(affected_exe) || guess_affected_service(affected_exe)
  end
  def get_service_by_package(exe)
    raise 'Implement in subclass!'
  end
  def guess_affected_service(exe,services=SRV_MANAGER.services)
    services.select do |service|
      s = service.gsub(ignored_names, "")
      e = File.basename(exe)
      c = longest_common_substr([e, s])
      if service_mapping[e]
        c2 = longest_common_substr([service_mapping[e], s])
        c = [c,c2].max
      end
      c.length > 3
    end
  end

  def filter_services(as)
    as_todo = as.select{|s| SRV_MANAGER.check_service(s) }

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

  def get_service_by_package(exe)
    package = get_package(exe)
    if $?.to_i > 0
      Log.debug("Could not file package for #{exe}")
      return nil
    end
    possible_services = list_files_of_package(package).split("\n").collect{|l|
      File.basename(l,SRV_MANAGER.service_suffix) if SRV_MANAGER.get_service_paths.any?{|p| l.start_with?(p) }
    }.compact
    Log.debug("Posstible services for #{exe}: #{possible_services.join(', ')}")
    SRV_MANAGER.expand_services(guess_affected_service(exe,possible_services))
  end
  private
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
end

class RPMServiceGuesser < ServiceGuesser
  protected
  def get_package(exe)
    `rpm -qf #{shellescape(exe)} 2>/dev/null`.chomp
  end
  def list_files_of_package(package)
    `rpm -ql #{package}`
  end
end

class DPKGServiceGuesser < ServiceGuesser
  protected
  def get_package(exe)
    `dpkg -S #{shellescape(exe)} 2>/dev/null`.chomp.split(':').first
  end
  def list_files_of_package(package)
    `dpkg -L #{package}`
  end
end

if File.exists?('/etc/redhat-release')
  SRV_GUESSER = RPMServiceGuesser.new
elsif File.exists?('/etc/debian_version')
  SRV_GUESSER = DPKGServiceGuesser.new
else
  raise 'Can\'t detect the right service guesser'
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
    name = name.split("@").first

    next if blacklist.include? name
    next unless SRV_MANAGER.services.include? name

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
  to_restart = SRV_GUESSER.guess_affected_services(affected)

  restart(to_restart)

  find_affected_exes(true)
end

JOBS.write unless OPTION[:dry_run]
