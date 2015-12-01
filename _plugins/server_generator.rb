module Jekyll
  class ServerPage < Page
    def initialize(site, base, dir, attributes)
      @site = site
      @base = base
      @dir = dir
      @name = 'index.md'

      process(@name)
      read_yaml(File.join(base, '_layouts'), 'server.md')
      data['server'] = extract_details(attributes['automatic'])
      data['title'] = attributes['name']
    end

    private

    def extract_details(ohai)
      {
        'system' => extract_system(ohai),
        'cpus' => extract_cpus(ohai),
        'memory' => extract_memory(ohai),
        'disk' => extract_disk(ohai),
        'network' => extract_network(ohai),
        'bios' => extract_bios(ohai),
        'os' => ohai['lsb']['description']
      }
    end

    def extract_system(ohai)
      system = {}

      if ohai['virtualization'] &&
         ohai['virtualization']['role'] == 'guest'
        case ohai['virtualization']['system']
        when "kvm" then system['name'] = "KVM Virtual Machine"
        when "vmware" then system['name'] = "VMWare Virtual Machine"
        when "xen" then system['name'] = "Xen Virtual Machine"
        else system['name'] = "Virtual Machine"
        end
      else
        if ohai['dmi']['system'] &&
           ohai['dmi']['system']['manufacturer'] != 'empty' &&
           ohai['dmi']['system']['manufacturer'] != 'System manufacturer'
          system_manufacturer = ohai['dmi']['system']['manufacturer'].squeeze(' ').strip
          system_product = ohai['dmi']['system']['product_name'].squeeze(' ').strip
          system_sku = ohai['dmi']['system']['sku_number'].squeeze(' ').strip
        end

        if ohai['dmi']['base_board'] &&
           ohai['dmi']['base_board']['product_name']
          base_board_manufacturer = ohai['dmi']['base_board']['manufacturer'].squeeze(' ').strip
          base_board_product = ohai['dmi']['base_board']['product_name'].squeeze(' ').strip
        end

        if system_manufacturer == base_board_manufacturer &&
           system_product == base_board_product
          system_manufacturer = nil
          system_product = nil
        end

        if system_manufacturer == 'IBM'
          system_product.sub!(/\s*-\[([0-9]{4})([A-Z]{3})\]-$/, ' \1-\2')
        end

        system_manufacturer = @site.data['names']['vendors'][system_manufacturer] || system_manufacturer
        base_board_manufacturer = @site.data['names']['vendors'][base_board_manufacturer] || base_board_manufacturer

        if system_manufacturer && system_product
          if system_manufacturer == 'HP' && system_sku != ''
            system['name'] = "#{system_manufacturer} #{system_product} (#{system_sku})"
          elsif system_product.start_with?(system_manufacturer)
            system['name'] = "#{system_product}"
          else
            system['name'] = "#{system_manufacturer} #{system_product}"
          end
        end

        if base_board_manufacturer && base_board_product
          system['motherboard'] = "#{base_board_manufacturer} #{base_board_product}"
        end
      end

      system
    end

    def extract_cpus(ohai)
      ohai['cpu']
        .select { |_, cpu| cpu.is_a?(Hash) && cpu['core_id'] == '0' }
        .map { |_, cpu| { :id => cpu['physical_id'], :model => cpu['model_name'].squeeze(' ').strip, :cores => cpu['cores'] } }
        .group_by { |cpu| cpu[:model] }
        .map { |model, cpus| { 'model' => model, 'cores' => cpus.first[:cores], 'count' => cpus.uniq.count } }
    end

    def extract_memory(ohai)
      {
        'total' => format_size(parse_size(ohai['memory']['total'])),
        'devices' => extract_memory_devices(ohai)
      }
    end

    def extract_memory_devices(ohai)
      if ohai['hardware']
        ohai['hardware']['memory']
          .reject { |device| device['type'] == 'Flash' }
          .map { |device| { :size => parse_size(device['size']), :type => describe_memory_device(device) } }
          .group_by { |device| device[:type] }
          .map { |type, devices| { 'type' => type, 'size' => devices.first[:size], 'count' => devices.count } }
          .sort_by { |device| device['size'] }
          .reverse
      else
        []
      end
    end

    def describe_memory_device(device)
      form_factor = device['form_factor']

      if device['size'] == 'No Module Installed'
        "Spare #{form_factor} slot"
      else
        size = format_size(parse_size(device['size']))
        type = device['type']
        speed = device['speed']

        if type.end_with?(form_factor)
          form_factor = ""
        end

        if speed == 'Unknown'
          "#{size} #{type} #{form_factor}".strip
        else
          "#{size} #{speed} #{type} #{form_factor}".strip
        end
      end
    end

    def extract_disk(ohai)
      {
        'controllers' => extract_disk_controllers(ohai),
        'arrays' => extract_disk_arrays(ohai),
        'disks' => extract_disk_disks(ohai)
      }
    end

    def extract_disk_controllers(ohai)
      if ohai['hardware']
        ohai['hardware']['pci']
          .select { |_, device| is_disk_controller(device) }
          .map { |_, device| device_name(device) }
          .sort
      else
        []
      end
    end

    def is_disk_controller(device)
      device['class_name'] == 'SATA controller' ||
        device['class_name'] == 'RAID bus controller' ||
        device['class_name'] == 'Serial Attached SCSI controller' ||
        device['class_name'] == 'Non-Volatile memory controller'
    end

    def extract_disk_arrays(ohai)
      if ohai['hardware'] && ohai['hardware']['disk']
        ohai['hardware']['disk']['arrays']
          .map { |array| array_details(array) }
          .sort_by { |array| array['device'] }
      else
        []
      end
    end

    def array_details(array)
      {
        'device' => array['device'],
        'size' => array['size'],
        'level' => array['raid_level'],
        'disks' => array['disks'].count
      }
    end

    def extract_disk_disks(ohai)
      if ohai['hardware'] && ohai['hardware']['disk']
        ohai['hardware']['disk']['disks']
          .map { |device| { :size => parse_size(device['size']), :type => describe_disk_device(device) } }
          .group_by { |device| device[:type] }
          .map { |type, devices| { 'type' => type, 'size' => devices.first[:size], 'count' => devices.count } }
          .sort_by { |device| device['size'] }
          .reverse
      else
        []
      end
    end

    def describe_disk_device(device)
      size = device['size']
      vendor = device['vendor']
      model = device['model']

      "#{size} #{vendor} #{model}"
    end

    def extract_network(ohai)
      {
        'controllers' => extract_network_controllers(ohai),
        'interfaces' => extract_network_interfaces(ohai)
      }
    end

    def extract_network_controllers(ohai)
      if ohai['hardware']
        ohai['hardware']['pci']
          .select { |_, device| device['class_name'] == 'Ethernet controller' }
          .select { |_, device| device['function'] == '0' }
          .map { |_, device| device_name(device) }
          .sort
      else
        []
      end
    end

    def extract_network_interfaces(ohai)
      ohai['network']['interfaces']
        .select { |_, interface| interface['encapsulation'] == 'Ethernet' }
        .map { |name, interface| { 'name' => name, 'addresses' => extract_addresses(interface) } }
        .sort_by { |interface| interface['name'] }
    end

    def extract_addresses(interface)
      interface['addresses']
        .reject { |address, properties| properties['scope'] == 'Link' }
        .map { |address, _| address }
    end

    def extract_bios(ohai)
      if bios = ohai['dmi']['bios']
        "#{bios['vendor']} version #{bios['version']}"
      end
    end

    def device_name(device)
      if device['subsystem_device_name'] =~ /^Device \h{4}$/ ||
         device['subsystem_vendor_name'] != device['vendor_name']
        vendor = device['vendor_name']
        name = device['device_name']
      else
        vendor = device['subsystem_vendor_name']
        name = device['subsystem_device_name']
      end

      vendor = @site.data['names']['vendors'][vendor] || vendor

      "#{vendor} #{name}"
    end

    def parse_size(size)
      if size =~ /^(\d+)(?:\.\d+)?\s*TB/i
        $1.to_i * 1024 * 1024 * 1024
      elsif size =~ /^(\d+)(?:\.\d+)?\s*GB/i
        $1.to_i * 1024 * 1024
      elsif size =~ /^(\d+)(?:\.\d+)?\s*MB/i
        $1.to_i * 1024
      elsif size =~ /^(\d+)(?:\.\d+)?\s*KB/i
        $1.to_i
      else
        0
      end
    end

    def format_size(kb)
      if kb == 0
        ""
      else
        kblog2 = Math.log2(kb).ceil

        if kblog2 >= 30
          sprintf "%dTB", 2 ** (kblog2 - 30)
        elsif kblog2 >= 20
          sprintf "%dGB", 2 ** (kblog2 - 20)
        elsif kblog2 >= 10
          sprintf "%dMB", 2 ** (kblog2 - 10)
        else
          sprintf "%dKB", 2 ** (kblog2 - 0)
        end
      end
    end
  end

  class ServerPageGenerator < Generator
    safe true

    def generate(site)
      dir = 'servers'
      site.data['nodes']['rows'].each do |server|
        site.pages << ServerPage.new(site, site.source, File.join(dir, server['name']), server)
      end
    end
  end
end
