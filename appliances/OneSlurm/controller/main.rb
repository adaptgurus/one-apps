# frozen_string_literal: true

begin
    require '/etc/one-appliance/lib/helpers'
rescue LoadError
    require_relative '../../lib/helpers'
end

require 'socket'
require 'open3'
require 'rbconfig'
require 'fileutils'
require 'base64'

require_relative '../common/onegate'
require_relative '../common/ldap'
require_relative '../common/munge'
require_relative '../common/slurm'
require_relative '../common/infiniband'
require_relative 'config'

module Service
    module SlurmController
        extend self

        include OneSlurm::Ldap
        include OneSlurm::Munge
        include OneSlurm::Slurm
        include OneSlurm::Infiniband

        DEPENDS_ON = []

        def install
            msg :info, 'SlurmController::install'
            bash 'apt update && apt install munge libmunge-dev slurmctld slurm-client slurm-wlm-basic-plugins ldap-utils sssd sssd-ldap libnss-sss libpam-sss nfs-common -y'
            install_infiniband_packages

            # Install-time config remains compatible with the single-controller
            # image build. configure() rewrites it from authoritative OneFlow
            # membership when the service starts.
            write_controller_slurm_config
            bash 'systemctl enable slurmctld'
            install_node_reconciler

            msg :info, 'Installation completed successfully'
        end

        def install_infiniband_packages
            return unless INSTALL_INFINIBAND == 'true'

            install_controller_infiniband_packages
        end

        def controller_topology
            controllers = role_vms_show('controller').sort_by do |vm|
                Integer(vm.dig('VM', 'ID').to_s, 10)
            rescue ArgumentError
                raise 'FATAL: Controller VM is missing a numeric OpenNebula VM ID'
            end

            if slurm_ha_enabled? && controllers.length < 2
                raise 'FATAL: ONEAPP_SLURM_HA_ENABLE=YES requires at least two controller role VMs'
            end
            if !slurm_ha_enabled? && controllers.length != 1
                raise 'FATAL: Multiple controller role VMs require ONEAPP_SLURM_HA_ENABLE=YES'
            end

            controllers.each_with_index.map do |vm, index|
                ip = vm_nic_ipv4(vm)
                raise "FATAL: Controller VM #{vm.dig('VM', 'ID')} has no IPv4 address" if ip.empty?

                {
                    vm: vm,
                    vmid: vm.dig('VM', 'ID').to_s,
                    name: controllers.length == 1 && !slurm_ha_enabled? ?
                          OneSlurm::Slurm::LEGACY_CONTROLLER_NAME :
                          "slurm-one-controller-#{index + 1}",
                    ip: ip,
                    primary: index.zero?
                }
            end
        end

        def current_vm_id
            onegate_vm_show.dig('VM', 'ID').to_s
        end

        def local_controller(topology)
            id = current_vm_id
            controller = topology.find { |item| item[:vmid] == id }
            raise "FATAL: Current VM #{id} is not present in controller role membership" unless controller

            controller
        end

        def configure_controller_identity(topology, local)
            current_hostname = Socket.gethostname.split('.').first
            desired_hostname = local[:name]

            if current_hostname != desired_hostname
                msg :info, "Hostname is '#{current_hostname}', changing to '#{desired_hostname}'"
                bash "hostnamectl set-hostname #{desired_hostname}"
            end

            hosts = File.read('/etc/hosts')
            File.open('/etc/hosts', 'a') do |f|
                topology.each do |controller|
                    hosts_entry = "#{controller[:ip]}\t#{controller[:name]}"
                    next if hosts.include?(hosts_entry)

                    msg :info, "Adding '#{hosts_entry}' to /etc/hosts"
                    f.puts hosts_entry
                end
            end
        end

        def validate_ha_identity_policy!(topology)
            return unless topology.length > 1

            if truthy?(ONEAPP_LDAP_ENABLE)
                raise 'FATAL: Local slapd identity is not supported for HA OneSlurm. ' \
                      'Use a qualified external LDAP/AD endpoint or disable LDAP.'
            end

            state_path = slurm_state_save_location
            if state_path == OneSlurm::Slurm::DEFAULT_STATE_SAVE_LOCATION
                raise 'FATAL: HA OneSlurm requires ONEAPP_SLURM_STATE_SAVE_LOCATION ' \
                      'to point to durable shared storage mounted on every controller.'
            end

            raise "FATAL: Shared Slurm state path '#{state_path}' is not mounted" unless mountpoint?(state_path)
        end

        def mountpoint?(path)
            _out, _err, status = Open3.capture3('mountpoint', '-q', path)
            status.success?
        rescue Errno::ENOENT
            false
        end

        def wait_for_primary_coordination(primary, attempts: 40, delay: 5)
            attempts.times do |i|
                vm = onegate_vm_show(primary[:vmid])
                template = vm.dig('VM', 'USER_TEMPLATE') || {}
                key = template['SLURM_MUNGE_KEY'].to_s
                ready = template['READY'].to_s == 'YES'
                return [key, template] if ready && !key.empty?

                raise 'FATAL: Primary controller did not publish coordination state' if i + 1 == attempts

                msg :warn, "Primary controller coordination is not ready; retrying in #{delay}s (#{i + 1}/#{attempts})"
                sleep delay
            end
        end

        def install_node_reconciler
            msg :info, 'Installing OneSlurm node reconciler'

            reconciler = <<~'RUBY'
                #!/usr/bin/env ruby
                # frozen_string_literal: true
                require 'json'
                require 'open3'

                def run(cmd)
                    out, _err, st = Open3.capture3(*cmd)
                    [out, st.success?]
                end

                def log(text)
                    puts "[oneslurm-reconcile] #{text}"
                end

                svc_out, ok = run(['onegate', '--json', 'service', 'show'])
                unless ok
                    log 'OneGate service show failed or unavailable; skipping'
                    exit 0
                end

                begin
                    svc = JSON.parse(svc_out)
                rescue StandardError => e
                    log "Could not parse OneGate service JSON: #{e.message}; skipping"
                    exit 0
                end

                roles = svc.dig('SERVICE', 'roles') || []
                worker_role = roles.find { |r| r['name'] == 'worker' }
                if worker_role.nil?
                    log 'No worker role in OneGate service; skipping'
                    exit 0
                end

                vmids = (worker_role['nodes'] || []).map { |n| n.dig('vm_info', 'VM', 'ID') }.compact
                live = []
                vmids.each do |vmid|
                    out, ok = run(['onegate', '--json', 'vm', 'show', vmid.to_s])
                    next unless ok

                    begin
                        vm = JSON.parse(out)
                    rescue StandardError
                        next
                    end

                    name = vm.dig('VM', 'USER_TEMPLATE', 'SLURM_NODENAME').to_s.strip
                    live << name unless name.empty?
                end

                if live.empty?
                    log 'No live SLURM_NODENAME values resolved yet; skipping'
                    exit 0
                end

                nodes_out, ok = run(['scontrol', '-o', 'show', 'nodes'])
                exit 0 unless ok

                registered = {}
                nodes_out.each_line do |line|
                    name = line[/NodeName=(\S+)/, 1]
                    state = line[/State=(\S+)/, 1].to_s
                    registered[name] = state if name
                end

                stale = registered.select do |name, state|
                    !live.include?(name) && state =~ /DOWN|NOT_RESPONDING/i
                end.keys

                if stale.empty?
                    log 'No stale nodes to reconcile'
                    exit 0
                end

                stale.each do |name|
                    active, _ = run(['squeue', '-h', '-w', name, '-t', 'RUNNING,COMPLETING', '-o', '%i'])
                    if active.strip.empty?
                        _, ok = run(['scontrol', 'delete', "NodeName=#{name}"])
                        log(ok ? "deleted stale node #{name}" : "failed to delete node #{name}")
                    else
                        _, ok = run(['scontrol', 'update', "NodeName=#{name}", 'State=DRAIN',
                                     'Reason=removed from OneFlow service with active allocations'])
                        log(ok ? "drained node #{name} (active allocations remain)" : "failed to drain node #{name}")
                    end
                end
            RUBY
            file '/usr/local/sbin/oneslurm-reconcile-nodes', reconciler,
                 mode: 'u=rwx,go=rx', overwrite: true

            service_unit = <<~UNIT
                [Unit]
                Description=OneSlurm controller node reconciler
                After=slurmctld.service network-online.target

                [Service]
                Type=oneshot
                ExecStart=/bin/bash -c 'set -a; [ -f /var/run/one-context/one_env ] && . /var/run/one-context/one_env; exec /usr/local/sbin/oneslurm-reconcile-nodes'
            UNIT
            file '/etc/systemd/system/oneslurm-reconcile.service', service_unit,
                 mode: 'u=rw,go=r', overwrite: true

            timer_unit = <<~UNIT
                [Unit]
                Description=Run OneSlurm node reconciler periodically

                [Timer]
                OnBootSec=120s
                OnUnitActiveSec=60s
                Unit=oneslurm-reconcile.service

                [Install]
                WantedBy=timers.target
            UNIT
            file '/etc/systemd/system/oneslurm-reconcile.timer', timer_unit,
                 mode: 'u=rw,go=r', overwrite: true
        end

        def enable_node_reconciler
            msg :info, 'Enabling OneSlurm node reconciler timer'
            bash 'systemctl daemon-reload'
            bash 'systemctl enable --now oneslurm-reconcile.timer'
        end

        def configure
            msg :info, 'SlurmController::configure'
            topology = controller_topology
            local = local_controller(topology)
            primary = topology.first

            validate_ha_identity_policy!(topology)
            configure_controller_identity(topology, local)
            write_controller_slurm_config(controller_hosts: topology,
                                          state_save_location: slurm_state_save_location)

            if local[:primary]
                generate_munge_key unless munge_key_generated?
            else
                key, = wait_for_primary_coordination(primary)
                install_munge_key(key)
            end

            msg :info, 'Restarting slurmctld with authoritative controller topology'
            bash 'systemctl restart slurmctld'
            bash 'systemctl is-active slurmctld'

            ldap_result = configure_controller_ldap

            if local[:primary]
                case ldap_result
                when :clear
                    clear_ldap_onegate
                when String
                    publish_ldap_onegate(ldap_result) unless ldap_result.empty?
                end
                publish_coordination(topology)
            end

            enable_node_reconciler
            msg :info, 'Configuration completed successfully'
        end

        def publish_coordination(topology)
            with_retries(msg: 'Attempting to update VM data in OneGate...') do
                msg :info, 'Publishing authoritative Slurm coordination data to OneGate'
                endpoints = topology.map { |item| "#{item[:ip]}:6817" }.join(',')
                onegate_vm_update [
                    "SLURM_MUNGE_KEY=#{munge_key_base64}",
                    "SLURM_CONTROLLER_ENDPOINTS=#{endpoints}",
                    'READY=YES'
                ]
            end
            msg :info, 'Successfully published Slurm coordination data to OneGate'
        end

        def publish_ldap_onegate(ldap_url)
            with_retries(msg: 'Attempting to update OneGate with LDAP metadata...') do
                msg :info, 'Updating OneGate with LDAP connection metadata'
                bash "onegate vm update --data LDAP_URL=#{ldap_url}"
                bash "onegate vm update --data LDAP_DOMAIN=#{ONEAPP_LDAP_DOMAIN}"
                admin_user = ONEAPP_LDAP_ADMIN_USER.to_s.strip
                bash "onegate vm update --data LDAP_ADMIN_USER=#{admin_user}" unless admin_user.empty?
                bind_user = ONEAPP_LDAP_BIND_USER.to_s.strip
                unless bind_user.empty?
                    bash "onegate vm update --data LDAP_BIND_USER=#{bind_user}"
                    bind_password = ONEAPP_LDAP_BIND_PASSWORD.to_s
                    bash "onegate vm update --data LDAP_BIND_PASSWORD=#{bind_password}" unless bind_password.empty?
                end
            end
            msg :info, 'Successfully updated OneGate with LDAP metadata'
        end

        def clear_ldap_onegate
            with_retries(msg: 'Attempting to clear LDAP metadata in OneGate...') do
                msg :info, 'Clearing LDAP connection metadata in OneGate'
                bash 'onegate vm update --data LDAP_URL='
            end
            msg :info, 'Successfully cleared LDAP metadata in OneGate'
        end

        def bootstrap
            msg :info, 'SlurmController::bootstrap'
            msg :info, 'Bootstrap completed successfully'
        end

    end
end
