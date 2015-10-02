Facter.add('reboot_monkey_services') do
  setcode do
    reboot_file = '/var/run/reboot-monkey'
    if File.exists?(reboot_file)
      File.read(reboot_file).split("\n").join(',')
    else
      ''
    end
  end
end

