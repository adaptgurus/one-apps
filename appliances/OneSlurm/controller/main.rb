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
require 'shellwords'

require_relative '../common/onegate'
require_relative '../common/ldap'
require_relative '../common/munge'
require_relative '../common/slurm'
require_relative '../common/infiniband'
require_relative 'config'

# Base module for OpenNebula services
module Service

    # SlurmController service implementation
    module SlurmController

        extend self

        include OneSlurm::Ldap
        include OneSlurm::Munge
        include OneSlurm::Slurm
        include OneSlurm::Infiniband

        DEPENDS_ON    = []

        def install
            msg :info, 'SlurmController::install'

            # Install dependencies
            bash 'apt update && apt install munge libmunge-dev slurmctld slurm-client slurm-wlm-basic-plugins ldap-utils sssd sssd-ldap libnss-sss libpam-sss nfs-common -y'
            install_infiniband_packages

            # Write cluster configuration
            write_controller_slurm_config

            # Enable service
            bash 'systemctl enable slurmctld'

            # Bake the scale-down node reconciler (script + systemd units) into
            # the image; the timer is enabled at configure time.
            install_node_reconciler
            install_scale_in_preflight

            msg :info, 'Installation completed successfully'
        end

        def install_infiniband_packages
            return unless INSTALL_INFINIBAND == 'true'

            install_controller_infiniband_packages
        end

        # Writes the reconciler script and systemd service/timer units. The
        # reconciler removes Slurm dynamic nodes whose worker VM is no longer
        # part of the OneFlow service (scale-down / deletion).
        def install_scale_in_preflight
            msg :info, 'Installing OneSlurm scale-in preflight'

            script = <<~'BASH'
                #!/usr/bin/env bash
                set -euo pipefail

                NODE="${1:-}"
                if [[ -z "$NODE" || ! "$NODE" =~ ^[A-Za-z0-9._-]+$ ]]; then
                    echo "usage: oneslurm-scale-in-preflight <node>" >&2
                    exit 64
                fi

                if ! scontrol show node "$NODE" >/dev/null 2>&1; then
                    echo "UNKNOWN: Slurm node '$NODE' does not exist" >&2
                    exit 69
                fi

                # New work must stop before the final busy check to avoid a
                # race between admission and VM termination.
                scontrol update NodeName="$NODE" State=DRAIN Reason="LayerSentry scale-in preflight"

                ACTIVE=$(squeue -h -w "$NODE" -t RUNNING,COMPLETING,CONFIGURING -o '%i' || true)
                if [[ -n "$ACTIVE" ]]; then
                    echo "BUSY: node '$NODE' still owns active jobs: $ACTIVE" >&2
                    exit 75
                fi

                # Re-read authoritative Slurm state after drain.
                STATE=$(scontrol -o show node "$NODE" | sed -n 's/.* State=\([^ ]*\).*/\1/p')
                if [[ -z "$STATE" ]]; then
                    echo "UNKNOWN: could not read final state for '$NODE'" >&2
                    exit 69
                fi

                echo "SAFE: node=$NODE state=$STATE"
            BASH

            file '/usr/local/sbin/oneslurm-scale-in-preflight', script,
                 mode: 'u=rwx,go=rx', overwrite: true
        end

        def install_node_reconciler
            msg :info, 'Installing OneSlurm node reconciler'

            reconciler = <<~'RUBY'
                #!/usr/bin/env ruby
                # frozen_string_literal: true
                # OneSlurm controller node reconciler.
                # Deletes Slurm dynamic nodes whose worker VM has left the OneFlow
                # service (scale-down / deletion). Drains instead of deleting when a
                # stale node still has running jobs. Safe no-op for standalone deploys.
                require 'json'
                require 'open3'

                def run(cmd)
                    out, _err, st = Open3.capture3(*cmd)
                    [out, st.success?]
                end

                def log(text)
                    puts "[oneslurm-reconcile] #{text}"
                end

                # 1. Live worker node names from OneGate service membership.
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

                # `service show` only embeds a VM summary (ID/NAME), so fetch each
                # worker VM individually to read its published SLURM_NODENAME.
                vmids = (worker_role['nodes'] || []).map do |n|
                    n.dig('vm_info', 'VM', 'ID')
                end.compact

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

                # Never act if we cannot resolve any live node names (avoids mass
                # deletion before workers publish SLURM_NODENAME or on transient
                # OneGate errors).
                if live.empty?
                    log 'No live SLURM_NODENAME values resolved yet; skipping'
                    exit 0
                end

                # 2. Registered nodes + state from the controller.
                nodes_out, ok = run(['scontrol', '-o', 'show', 'nodes'])
                exit 0 unless ok

                registered = {}
                nodes_out.each_line do |line|
                    name  = line[/NodeName=(\S+)/, 1]
                    state = line[/State=(\S+)/, 1].to_s
                    registered[name] = state if name
                end

                # 3. Stale = registered, not live, and currently down / not responding.
                stale = registered.select do |name, state|
                    !live.include?(name) && state =~ /DOWN|NOT_RESPONDING/i
                end.keys

                if stale.empty?
                    log 'No stale nodes to reconcile'
                    exit 0
                end

                # 4. Delete stale nodes; drain (keep) if they still hold running jobs.
                stale.each do |name|
                    running, _ = run(['squeue', '-h', '-w', name, '-t', 'RUNNING', '-o', '%i'])
                    if running.strip.empty?
                        _, ok = run(['scontrol', 'delete', "NodeName=#{name}"])
                        log(ok ? "deleted stale node #{name}" : "failed to delete node #{name}")
                    else
                        _, ok = run(['scontrol', 'update', "NodeName=#{name}", 'State=DRAIN',
                                     'Reason=removed from OneFlow service'])
                        log(ok ? "drained node #{name} (still has running jobs)" : "failed to drain node #{name}")
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

        def truthy?(value)
            %w[1 true yes on].include?(value.to_s.strip.downcase)
        end

        def current_vm_id
            vm = onegate_vm_show
            id = vm.dig('VM', 'ID').to_s
            raise 'FATAL: Could not determine current controller VM ID from OneGate' if id.empty?

            id
        end

        def controller_records
            vms = role_vms_show('controller')
            raise 'FATAL: No controller VMs found in OneGate service' if vms.empty?

            multi = vms.length > 1
            preferred_network = ENV['ONEAPP_SLURM_SERVICE_NETWORK'].to_s

            vms.map do |vm|
                vmid = vm.dig('VM', 'ID').to_s
                raise 'FATAL: Controller VM is missing ID' if vmid.empty?

                ip = vm_nic_ipv4(vm, preferred_network: preferred_network)
                raise "FATAL: Controller VM #{vmid} has no usable IPv4 address" if ip.empty?

                {
                    vmid: vmid,
                    name: multi ? "slurm-one-controller-#{vmid}" : 'slurm-one-controller',
                    ip: ip,
                    vm: vm
                }
            end.sort_by { |record| record[:vmid].to_i }
        end

        def configure_controller_identity(records)
            vmid = current_vm_id
            self_record = records.find { |record| record[:vmid] == vmid }
            raise "FATAL: Current VM #{vmid} is not present in controller role" if self_record.nil?

            desired_hostname = self_record[:name]
            current_hostname = Socket.gethostname.split('.').first
            if current_hostname != desired_hostname
                msg :info, "Hostname is '#{current_hostname}', changing to '#{desired_hostname}'"
                bash "hostnamectl set-hostname #{Shellwords.escape(desired_hostname)}"
            end

            hosts = File.read('/etc/hosts')
            File.open('/etc/hosts', 'a') do |file_handle|
                records.each do |record|
                    entry = "#{record[:ip]}\t#{record[:name]}"
                    next if hosts.include?(entry)

                    msg :info, "Adding '#{entry}' to /etc/hosts"
                    file_handle.puts entry
                end
            end

            self_record
        end

        def validate_shared_controller_state!(records)
            state_dir = ONEAPP_SLURM_STATE_SAVE_LOCATION.to_s.strip
            raise 'FATAL: ONEAPP_SLURM_STATE_SAVE_LOCATION must not be empty' if state_dir.empty?

            return if records.length == 1

            FileUtils.mkdir_p(state_dir)
            escaped = Shellwords.escape(state_dir)
            begin
                bash "mountpoint -q #{escaped}"
            rescue StandardError
                raise "FATAL: Multi-controller OneSlurm requires #{state_dir} to be a dedicated shared mount"
            end
        end

        def configure_cluster_munge(records, self_record)
            configured_key = ONEAPP_SLURM_MUNGE_KEY_BASE64.to_s.strip
            unless configured_key.empty?
                return if munge_key_generated? && munge_key_base64 == configured_key

                install_munge_key(configured_key)
                FileUtils.touch(OneSlurm::Munge::MUNGE_KEY_FLAG)
                return
            end

            primary = records.first

            if self_record[:vmid] == primary[:vmid]
                generate_munge_key unless munge_key_generated?
                # Publish only the bootstrap secret, not READY, so backups can
                # obtain the same key before the primary finishes configuring.
                with_retries(msg: 'Publishing primary controller MUNGE bootstrap data') do
                    onegate_vm_update [
                        "SLURM_MUNGE_KEY=#{munge_key_base64}",
                        "SLURM_CONTROLLER_NAME=#{self_record[:name]}"
                    ]
                end
                return
            end

            key = with_retries(attempts: 20, delay: 10,
                               msg: 'Waiting for primary controller MUNGE key') do
                primary_vm = onegate_vm_show(primary[:vmid])
                value = primary_vm.dig('VM', 'USER_TEMPLATE', 'SLURM_MUNGE_KEY').to_s
                raise 'Primary controller has not published its MUNGE key yet' if value.empty?

                value
            end

            return if munge_key_generated? && munge_key_base64 == key

            install_munge_key(key)
            FileUtils.touch(OneSlurm::Munge::MUNGE_KEY_FLAG)
        end

        def accounting_host
            return '' unless truthy?(ONEAPP_SLURM_ACCOUNTING_ENABLE)

            host = ONEAPP_SLURM_ACCOUNTING_HOST.to_s.strip
            if host.empty?
                raise 'FATAL: ONEAPP_SLURM_ACCOUNTING_ENABLE requires ONEAPP_SLURM_ACCOUNTING_HOST'
            end

            host
        end

        def configure
            msg :info, 'SlurmController::configure'

            records = controller_records
            self_record = configure_controller_identity(records)
            validate_shared_controller_state!(records)

            write_controller_slurm_config(
                controller_hosts: records.map { |record| record[:name] },
                state_save_location: ONEAPP_SLURM_STATE_SAVE_LOCATION,
                cluster_name: ONEAPP_SLURM_CLUSTER_NAME,
                max_node_count: ONEAPP_SLURM_MAX_NODE_COUNT,
                accounting_host: accounting_host,
                accounting_port: ONEAPP_SLURM_ACCOUNTING_PORT,
                constrain_cores: truthy?(ONEAPP_SLURM_CONSTRAIN_CORES),
                constrain_ram: truthy?(ONEAPP_SLURM_CONSTRAIN_RAM),
                constrain_swap: truthy?(ONEAPP_SLURM_CONSTRAIN_SWAP),
                constrain_devices: truthy?(ONEAPP_SLURM_CONSTRAIN_DEVICES)
            )

            configure_cluster_munge(records, self_record)

            msg :info, 'Ensuring slurmctld is running with the current cluster configuration'
            bash 'systemctl restart slurmctld'
            bash 'systemctl is-active slurmctld'
            apply_slurmctld_config

            if records.length > 1 && ONEAPP_LDAP_ENABLE
                msg :warn, 'Local LDAP is enabled with multiple controllers; production HA should use a qualified external redundant directory'
            end

            # Configure identity (local slapd or external client) and publish
            # LDAP_URL / LDAP_DOMAIN to OneGate.
            ldap_result = configure_controller_ldap
            case ldap_result
            when :clear
                clear_ldap_onegate
            when String
                publish_ldap_onegate(ldap_result) unless ldap_result.empty?
            end

            # Publish coordination data so workers can discover all READY
            # controllers and verify they share one MUNGE key.
            publish_coordination

            # Start the periodic reconciler that removes scaled-down workers.
            enable_node_reconciler

            msg :info, 'Configuration completed successfully'
        end

        def publish_coordination
            controller_name = Socket.gethostname.split('.').first
            data = [
                "SLURM_CONTROLLER_NAME=#{controller_name}",
                'READY=YES'
            ]
            if ONEAPP_SLURM_MUNGE_KEY_BASE64.to_s.strip.empty?
                data.unshift("SLURM_MUNGE_KEY=#{munge_key_base64}")
            end

            with_retries(msg: 'Attempting to update VM data in OneGate...') do
                msg :info, 'Publishing Slurm coordination data to OneGate'
                onegate_vm_update data
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
                # Bind credentials are role-local secrets and are intentionally
                # not copied into generic OneGate VM metadata.
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
            # No bootstrap actions defined for the controller yet.
            msg :info, 'Bootstrap completed successfully'
        end

    end
end
