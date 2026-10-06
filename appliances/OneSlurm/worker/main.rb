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
require 'json'

require_relative '../common/onegate'
require_relative '../common/ldap'
require_relative '../common/munge'
require_relative '../common/slurm'
require_relative '../common/infiniband'
require_relative 'config'

module Service
    module SlurmWorker
        extend self

        include OneSlurm::Ldap
        include OneSlurm::Munge
        include OneSlurm::Slurm
        include OneSlurm::Infiniband

        DEPENDS_ON = []

        def install
            msg(:info, 'SlurmWorker::install')
            bash('apt update && apt install munge libmunge-dev slurmd slurm-client slurm-wlm-basic-plugins sssd sssd-ldap libnss-sss libpam-sss ldap-utils nfs-common -y')
            install_infiniband_packages
            install_nvidia_drivers
            bash('systemctl disable slurmd')
            msg(:info, 'Installation completed successfully')
        end

        def install_infiniband_packages
            return unless INSTALL_INFINIBAND == 'true'

            install_worker_infiniband_packages
        end

        def install_nvidia_drivers
            return unless INSTALL_DRIVERS == 'true'

            install_nvidia_packages
        end

        def install_nvidia_packages
            bash <<~SCRIPT
                export DEBIAN_FRONTEND=noninteractive
                apt update
                apt install -y linux-headers-$(uname -r) build-essential dkms
                apt install -y nvidia-driver-#{NVIDIA_DRIVER_BRANCH}-server-open
                apt install -y nvidia-utils-#{NVIDIA_DRIVER_BRANCH}-server
            SCRIPT
        end

        def configure
            msg(:info, 'SlurmWorker::configure')

            controllers, munge_key_b64, ldap = discover_controllers
            endpoints = controllers.map { |controller| "#{controller[:ip]}:6817" }
            reachable = wait_for_any_controller(endpoints)
            msg(:info, "Using reachable Slurm controller #{reachable}")

            if ENV['SET_HOSTNAME'].to_s.empty?
                msg(:info, 'SET_HOSTNAME not set, configuring default hostname...')
                vm_id = nil
                10.times do |i|
                    begin
                        msg(:info, "Attempting to get VM info from onegate (#{i + 1}/10)")
                        vm_info_json = bash('onegate vm show -j')
                        vm_info = JSON.parse(vm_info_json)
                        vm_id = vm_info['VM']['ID']
                        break
                    rescue StandardError => e
                        if i + 1 < 10
                            sleep 15
                        else
                            raise "FATAL: Failed to get VM ID from onegate after 10 attempts: #{e.message}"
                        end
                    end
                end

                new_hostname = "slurm-one-worker-#{vm_id}"
                msg(:info, "Setting hostname to #{new_hostname}")
                bash("hostnamectl set-hostname #{new_hostname}")
            end

            hostname = Socket.gethostname.split('.').first
            ip = Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? }.ip_address

            hosts_entries = ["#{ip}\t#{hostname}"]
            controllers.each do |controller|
                hosts_entries << "#{controller[:ip]}\t#{controller[:name]}"
            end
            hosts = File.read('/etc/hosts')
            File.open('/etc/hosts', 'a') do |f|
                hosts_entries.each do |hosts_entry|
                    next if hosts.include?(hosts_entry)

                    msg(:info, "Adding '#{hosts_entry}' to /etc/hosts")
                    f.puts(hosts_entry)
                end
            end

            if infiniband_enabled?
                configure_ipoib(ip)
            else
                msg(:info, 'InfiniBand support disabled, skipping IPoIB configuration')
            end

            install_munge_key(munge_key_b64)

            sleep 5
            msg(:info, 'Starting slurmd and registering with controller set')
            write_slurmd_unit(hostname, controller_servers: endpoints)
            msg(:info, 'slurmd started')

            publish_node_name(hostname)
            install_scale_in_guard
            install_self_drain_hook
            configure_worker_ldap(ldap)

            msg(:info, 'Configuration completed successfully')
        end

        def wait_for_any_controller(endpoints, attempts: 10, delay: 10)
            attempts.times do |attempt|
                endpoints.each do |endpoint|
                    host, port = endpoint.split(':', 2)
                    return endpoint if tcp_port_open?(host, Integer(port || '6817', 10))
                end

                raise "FATAL: No Slurm controller reachable at #{endpoints.join(',')}" if attempt + 1 == attempts

                msg(:warn, "No Slurm controller reachable; retrying in #{delay}s (#{attempt + 1}/#{attempts})")
                sleep delay
            end
        end

        def publish_node_name(hostname)
            with_retries(msg: 'Attempting to publish Slurm node name to OneGate...') do
                msg(:info, "Publishing Slurm node name '#{hostname}' to OneGate")
                onegate_vm_update(["SLURM_NODENAME=#{hostname}"])
            end
        rescue StandardError => e
            msg(:warn, "Could not publish Slurm node name to OneGate: #{e.message}")
        end

        def install_scale_in_guard
            guard = <<~'SCRIPT'
                #!/bin/bash
                set -euo pipefail
                export SLURM_CONF=/run/slurm/conf/slurm.conf
                [ -f "$SLURM_CONF" ] || export SLURM_CONF=/etc/slurm/slurm.conf
                NODE="${1:-$(hostname -s)}"

                if ! scontrol show node "$NODE" >/dev/null 2>&1; then
                    echo "UNKNOWN: Slurm node '$NODE' is not authoritative/reachable" >&2
                    exit 2
                fi

                ACTIVE=$(squeue -h -w "$NODE" -t RUNNING,COMPLETING -o '%i' 2>/dev/null || true)
                if [ -n "$ACTIVE" ]; then
                    echo "BLOCKED: Slurm node '$NODE' still has active allocations: $ACTIVE" >&2
                    exit 75
                fi

                echo "SAFE: Slurm node '$NODE' has no RUNNING/COMPLETING allocations"
            SCRIPT
            file '/usr/local/sbin/oneslurm-can-remove-worker', guard,
                 mode: 'u=rwx,go=rx', overwrite: true
        end

        def install_self_drain_hook
            msg(:info, 'Installing OneSlurm worker self-drain shutdown hook')

            drain_script = <<~'SCRIPT'
                #!/bin/bash
                set -u
                export SLURM_CONF=/run/slurm/conf/slurm.conf
                [ -f "$SLURM_CONF" ] || export SLURM_CONF=/etc/slurm/slurm.conf
                NODE=$(hostname -s)

                if ! /usr/local/sbin/oneslurm-can-remove-worker "$NODE"; then
                    timeout 15 scontrol update NodeName="$NODE" State=DRAIN \
                        Reason="worker shutdown with active or unknown allocation state" 2>/dev/null || true
                    exit 0
                fi

                timeout 15 scontrol update NodeName="$NODE" State=DRAIN \
                    Reason="planned OneFlow scale-down" 2>/dev/null || true
                timeout 15 scontrol delete NodeName="$NODE" 2>/dev/null || true
            SCRIPT
            file '/usr/local/sbin/oneslurm-self-drain.sh', drain_script,
                 mode: 'u=rwx,go=rx', overwrite: true

            unit = <<~UNIT
                [Unit]
                Description=OneSlurm worker self-drain on shutdown
                After=slurmd.service munge.service network-online.target

                [Service]
                Type=oneshot
                RemainAfterExit=yes
                ExecStart=/bin/true
                ExecStop=/usr/local/sbin/oneslurm-self-drain.sh

                [Install]
                WantedBy=multi-user.target
            UNIT
            file '/etc/systemd/system/oneslurm-self-drain.service', unit,
                 mode: 'u=rw,go=r', overwrite: true

            bash('systemctl daemon-reload')
            bash('systemctl enable --now oneslurm-self-drain.service')
        end

        def discover_controllers(retries = 20, seconds = 15)
            msg(:info, 'Discovering Slurm controllers through OneGate')

            retries.downto(0).each do |retry_num|
                begin
                    controller_vms = role_vms_show('controller').sort_by do |vm|
                        Integer(vm.dig('VM', 'ID').to_s, 10)
                    end
                    raise 'No controller VMs found' if controller_vms.empty?

                    controllers = controller_vms.each_with_index.map do |vm, index|
                        ip = vm_nic_ipv4(vm)
                        raise "Controller VM #{vm.dig('VM', 'ID')} has no IPv4" if ip.empty?

                        {
                            vmid: vm.dig('VM', 'ID').to_s,
                            name: controller_vms.length == 1 ?
                                  OneSlurm::Slurm::LEGACY_CONTROLLER_NAME :
                                  "slurm-one-controller-#{index + 1}",
                            ip: ip
                        }
                    end

                    primary_template = controller_vms.first.dig('VM', 'USER_TEMPLATE') || {}
                    ready = primary_template['READY'] == 'YES'
                    key = primary_template['SLURM_MUNGE_KEY'].to_s

                    if ready && !key.empty?
                        ldap = {
                            'url' => primary_template['LDAP_URL'].to_s,
                            'domain' => primary_template['LDAP_DOMAIN'].to_s,
                            'bind_user' => primary_template['LDAP_BIND_USER'].to_s,
                            'bind_password' => primary_template['LDAP_BIND_PASSWORD'].to_s
                        }
                        return [controllers, key, ldap]
                    end

                    msg(:warn, "Primary controller not ready yet (READY=#{primary_template['READY']}), retrying in #{seconds}s...")
                rescue StandardError => e
                    msg(:warn, "OneGate controller discovery failed: #{e.message}. Retrying in #{seconds}s...")
                end

                raise 'FATAL: Could not discover ready Slurm controller set through OneGate.' if retry_num.zero?

                sleep seconds
            end
        end

        def configure_worker_ldap(ldap)
            url = ldap['url'].to_s
            domain = ldap['domain'].to_s

            if url.empty? || domain.empty?
                msg(:info, 'No LDAP published by controller, skipping SSSD setup')
                return
            end

            if url =~ %r{//(127\.0\.0\.1|localhost|\[?::1\]?)(:|/|$)}
                msg(:warn, "Refusing to configure worker SSSD against loopback LDAP URL '#{url}'; skipping")
                return
            end

            msg(:info, 'Configuring SSSD LDAP client from OneGate metadata')
            apply_sssd_ldap_client(url, domain, ldap['bind_user'].to_s, ldap['bind_password'].to_s)
            msg(:info, 'SSSD LDAP client configured successfully')
        end

        def bootstrap
            # No bootstrap actions defined for the worker.
        end

    end
end
