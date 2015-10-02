Facter.add('reboot_monkey') do
  setcode do
    !Facter.value(:reboot_monkey_services).split(',').empty?
  end
end

