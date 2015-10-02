#!/usr/bin/env ruby

require 'yaml'
require 'optparse'
require 'fileutils'
require 'facter'

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

if Process.uid != 0
  if OPTION[:dry_run]
    Log.warn("not running as root. Not all processes shown")
  else
    raise 'Must run as root'
  end
end

CONFIG_FILE = "/etc/restartmonkey.conf"
REBOOT_FILE = "/var/run"
SPOOL_PATH  = "/var/spool/restartmonkey"
SPOOL_FILE  = File::join(SPOOL_PATH, "jobs")

##### classes

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
    @services ||= find_services.sort
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

  def filter_non_running_and_blocked_services(svs)
    svs.select{|s| non_running_or_blocked_service?(s) }
  end
  def non_running_or_blocked_service?(service)
    !(CONFIG.blacklisted?(sanitize_name(service))||CONFIG.blacklisted?(service)) && check_service(service)
  end
  def expand_services(services)
    services.collect{|s|expand_service(s) }.flatten
  end
  def expand_service(service)
    service
  end
  def sanitize_name(name)
    name
  end
  private
  def find_services
    raise 'implement for the specific init system'
  end
end

class SystemdServiceManager < ServiceManager
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
  def get_service_paths
    ['/lib/systemd/system', '/usr/lib/systemd/system','/etc/rc.d/init.d','/etc/init.d']
  end
  def service_suffix
    '.service'
  end
  def expand_service(service)
    if service =~ /@$/
      self.services.select{|s| !CONFIG.blacklist?(service) && s.start_with?(service) && check_service(s) }
    else
      super(service)
    end
  end
  def sanitize_name(name)
    name.split('@').first
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
      shellescape(File.basename(s))
    end
  end
end

class Cnf
  def initialize
    @cnf = YAML::load_file(CONFIG_FILE) rescue {}
    @cnf['must_reboot'] ||= {}
    default_must_reboot = {
      'CentOS.7' => ['auditd'],
      'Debian.7' => ['dbus','screen-cleanup'],
    }
    default_must_reboot.keys.each{|k| @cnf['must_reboot'][k] = (@cnf['must_reboot'][k]||[])|default_must_reboot[k] }
    @cnf['blacklisted'] = (@cnf['blacklisted']||[])|["halt", "reboot", "libvirt-guests", "cryptdisks",
      "functions", "qemu-kvm", "rc", "netconsole",
      "network", "networking","killprocs", "mountall",
      "sendsigs",'xendomains']
  end

  def whitelisted?(service)
    (@cnf["whitelist"] || []).include? service
  end

  def ignored?(service)
    (@cnf["ignore"] || []).include? service
  end
  def blacklisted?(service)
    t = (@cnf["blacklisted"] || []).include? service
    Log.debug("Service #{service} is blacklisted") if t
    t
  end
  def must_reboot?(service)
    ["#{Facter.value('operatingsystem')}.#{Facter.value('operatingsystemmajrelease')}",
      Facter.value('operatingsystem'),
      'default'
    ].any?{|l| (@cnf['must_reboot'][l]||[]).include?(service) }
  end
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
    guessed_services = affected_exes.collect{|exe| get_affected_service(exe) }.flatten.uniq.sort
    filter_services(guessed_services)
  end

  protected
  def get_affected_service(affected_exe)
    s = get_services_by_package(affected_exe)
    s.empty? ? guess_affected_service(affected_exe) : s
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
    as_todo = as.select{|s| !CONFIG.blacklisted?(SRV_MANAGER.sanitize_name(s) ) }
    bs_as = as - as_todo
    as = as_todo

    as_todo = SRV_MANAGER.filter_non_running_and_blocked_services(as)
    skip_as = as - as_todo

    {
      "Probably affected"    => as_todo,
      "Ignoring blacklisted" => bs_as,
      "Ignoring non-running" => skip_as,
    }.each do |s,l|
      unless l.empty?
        Log.info "#{s} services:"
        l.each{|s| Log.info "* #{s}" }
      end
    end
    as_todo
  end

  def get_services_by_package(exe)
    package = get_package(exe)
    if $?.to_i > 0
      Log.debug("Could not file package for #{exe}")
      return nil
    end
    possible_services = list_files_of_package(package).split("\n").collect{|l|
      File.basename(l,SRV_MANAGER.service_suffix) if SRV_MANAGER.get_service_paths.any?{|p| l.start_with?(p) }
    }.compact
    Log.debug("Possible services for #{exe}: #{possible_services.join(', ')}")
    active_services = SRV_MANAGER.filter_non_running_and_blocked_services(possible_services)
    Log.debug("Active services for #{exe}: #{active_services.join(', ')}")
    SRV_MANAGER.expand_services(active_services)
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

class Jobs
  def initialize
    @jobs = (YAML::load_file(SPOOL_FILE) rescue {}) || {}
    @new_jobs = {}
    @wait_count = {}
  end

  def write
    FileUtils.mkdir_p(SPOOL_PATH)
    FileUtils.chmod_R(0600, SPOOL_PATH)
    File.open(SPOOL_FILE, 'w') {|f| f.write @new_jobs.to_yaml }
  end

  def schedule(name)
    if run_now?(name)
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
        Log.puts "Would schedule service '#{name}' to be restarted in #{wait_count(name)} runs"
      else
        Log.puts "Probably affected service '#{name}' is scheduled to be restarted in #{wait_count(name)} runs"
        dec_wait_count(name)
      end
    end
  end
  def run_now?(name)
    wait_count(name) == 0
  end
  def wait_count(name)
    @wait_count[name] ||= Integer(@jobs[name] || OPTION[:wait_count] || 0)
  end
  def dec_wait_count(name)
    @new_jobs[name] = wait_count(name) - 1
  end
end

class RebootManager
  attr_reader :reboot_services
  def initialize
    @reboot_services = []
  end

  def register_reboot(name)
    if OPTION[:dry_run]
      Log.info "Would register reboot for '#{name}'"
    else
      Log.info "Register '#{name}' for reboot"
      @reboot_services << name
    end
  end

  def reboot_pending?
    !@reboot_services.empty?
  end

  def flush
    unless OPTION[:dry_run]
      File.open('/var/run/reboot-monkey','w'){|f| f << @reboot_services.join("\n") }
    end
  end
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
  'bin\/(bash|perl|ruby|python)([\d\.]*|\.#prelink#)'
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

def print_affected(exes, libs)
  unless (libs.empty? && exes.empty?)
    Log.puts "\nCurrently the following problems persist:"
    unless REBOOT_MANAGER.reboot_pending?
      Log.puts "Reboot pending! (Services: #{REBOOT_MANAGER.reboot_services.join(', ')})"
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
  names.each do |name|
    sanitized_name = SRV_MANAGER.sanitize_name(name)

    if CONFIG.blacklisted?(sanitized_name)
      Log.debug "Skipping blacklisted service '#{name}'(Lookup: #{sanitized_name})"
      next
    end

    if CONFIG.ignored?(sanitized_name)
      Log.debug "Skipping ignored service '#{name}' (Lookup: #{sanitized_name})"
      next
    end

    if CONFIG.must_reboot?(sanitized_name)
      REBOOT_MANAGER.register_reboot(name)
      next
    end

    if CONFIG.whitelisted?(sanitized_name)
      JOBS.schedule(name)
    else
      Log.puts "Skipping restart of probably affected service '#{name}' since it's not whitelisted (Lookup: #{sanitized_name})"
    end
  end
end

### Runtime configuration

CONFIG = Cnf.new
JOBS = Jobs.new
REBOOT_MANAGER = RebootManager.new
SRV_MANAGER = if File.exists?('/usr/bin/systemctl')
  SystemdServiceManager.new
else
  InitVServiceManager.new
end

if File.exists?('/etc/redhat-release')
  SRV_GUESSER = RPMServiceGuesser.new
elsif File.exists?('/etc/debian_version')
  SRV_GUESSER = DPKGServiceGuesser.new
else
  raise 'Can\'t detect the right service guesser'
end

affected = find_affected_exes

if affected.size > 0
  to_restart = SRV_GUESSER.guess_affected_services(affected)

  restart(to_restart)

  find_affected_exes(true)
end

# save data

unless OPTION[:dry_run]
  JOBS.write
  REBOOT_MANAGER.flush
end

