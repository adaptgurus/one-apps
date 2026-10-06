# frozen_string_literal: true

# Shared Slurm configuration helpers: controller configuration generation,
# worker configless service generation and local resource discovery.
module OneSlurm

    module Slurm

        LEGACY_CONTROLLER_NAME = 'slurm-one-controller'
        DEFAULT_STATE_SAVE_LOCATION = '/var/spool/slurmctld'
        VALID_GPU_AUTODETECT = %w[nvidia nvml off].freeze

        def controller_ipv4
            Socket.ip_address_list
                  .find { |a| a.ipv4? && !a.ipv4_loopback? }
                  .ip_address
        end

        def truthy?(value)
            %w[1 true yes on].include?(value.to_s.strip.downcase)
        end

        def slurm_ha_enabled?
            defined?(ONEAPP_SLURM_HA_ENABLE) && truthy?(ONEAPP_SLURM_HA_ENABLE)
        end

        def slurm_state_save_location
            if defined?(ONEAPP_SLURM_STATE_SAVE_LOCATION)
                value = ONEAPP_SLURM_STATE_SAVE_LOCATION.to_s.strip
                return value unless value.empty?
            end

            DEFAULT_STATE_SAVE_LOCATION
        end

        def slurm_gpu_autodetect
            value = if defined?(ONEAPP_SLURM_GPU_AUTODETECT)
                        ONEAPP_SLURM_GPU_AUTODETECT.to_s.strip.downcase
                    else
                        'nvidia'
                    end
            value = 'nvidia' if value.empty?
            unless VALID_GPU_AUTODETECT.include?(value)
                raise "FATAL: Unsupported ONEAPP_SLURM_GPU_AUTODETECT='#{value}'. " \
                      "Allowed: #{VALID_GPU_AUTODETECT.join(', ')}"
            end
            value
        end

        # controller_hosts is an ordered array of hashes containing :name and,
        # optionally, :ip. The first entry is the native primary controller.
        def write_controller_slurm_config(controller_hosts: nil,
                                          state_save_location: nil,
                                          accounting_config: '')
            controller_hosts ||= [{ name: LEGACY_CONTROLLER_NAME }]
            controller_hosts = Array(controller_hosts)
            raise 'FATAL: At least one Slurm controller is required' if controller_hosts.empty?

            state_save_location = state_save_location.to_s.strip
            state_save_location = slurm_state_save_location if state_save_location.empty?

            if slurm_ha_enabled?
                raise 'FATAL: OneSlurm HA requires at least two controller VMs' if controller_hosts.length < 2

                if state_save_location == DEFAULT_STATE_SAVE_LOCATION
                    raise 'FATAL: OneSlurm HA requires a durable shared ' \
                          'ONEAPP_SLURM_STATE_SAVE_LOCATION; local /var/spool/slurmctld is not allowed'
                end
            end

            controller_lines = controller_hosts.map do |controller|
                name = controller[:name] || controller['name']
                ip = controller[:ip] || controller['ip']
                raise 'FATAL: Slurm controller name is empty' if name.to_s.strip.empty?

                if ip.to_s.strip.empty?
                    "SlurmctldHost=#{name}"
                else
                    "SlurmctldHost=#{name}(#{ip})"
                end
            end.join("\n")

            infiniband_config = slurm_infiniband_enabled? ? <<~CONF : ''
                MpiDefault=pmix
                PropagateResourceLimitsExcept=MEMLOCK
            CONF

            slurm_conf = <<~CONF
                ClusterName=one
                #{controller_lines}
                AuthType=auth/munge
                ProctrackType=proctrack/cgroup
                SchedulerType=sched/backfill
                SelectType=select/cons_tres
                GresTypes=gpu
                TaskPlugin=task/cgroup,task/affinity
                #{accounting_config}

                SlurmUser=slurm
                StateSaveLocation=#{state_save_location}
                SlurmdSpoolDir=/var/spool/slurmd

                SlurmctldPidFile=/var/run/slurm/slurmctld.pid
                SlurmdPidFile=/var/run/slurm/slurmd.pid

                SlurmctldParameters=enable_configless
                #{infiniband_config}

                MaxNodeCount=100

                Nodeset=one Feature=one

                PartitionName=all Nodes=ALL Default=yes
            CONF

            File.write('/etc/slurm/slurm.conf', slurm_conf)

            autodetect = slurm_gpu_autodetect
            gres_conf = autodetect == 'off' ? '' : "AutoDetect=#{autodetect}\n"
            File.write('/etc/slurm/gres.conf', gres_conf)

            cgroup_conf = <<~CONF
                CgroupPlugin=autodetect
                ConstrainCores=yes
                ConstrainRAMSpace=yes
                ConstrainSwapSpace=yes
                ConstrainDevices=yes
            CONF
            File.write('/etc/slurm/cgroup.conf', cgroup_conf)

            FileUtils.mkdir_p('/var/spool/slurmd')
            FileUtils.mkdir_p(state_save_location)
            FileUtils.chown_R('slurm', 'slurm', '/var/spool/slurmd')
            FileUtils.chown_R('slurm', 'slurm', state_save_location)
            FileUtils.chmod(0700, '/var/spool/slurmd')
            FileUtils.chmod(0700, state_save_location)
        end

        def slurm_infiniband_enabled?
            return false unless defined?(ONEAPP_SLURM_INFINIBAND_ENABLE)

            truthy?(ONEAPP_SLURM_INFINIBAND_ENABLE)
        end

        def apply_slurmctld_config
            msg :info, 'Applying updated slurm.conf to running slurmctld'
            bash 'systemctl is-active slurmctld'
            bash 'scontrol reconfigure'
        rescue StandardError => e
            msg :warn, "Could not apply slurmctld reconfigure: #{e.message}"
        end

        def write_slurmd_unit(hostname, controller_servers: nil)
            controller_servers = Array(controller_servers).map(&:to_s).map(&:strip).reject(&:empty?)
            controller_servers = ["#{LEGACY_CONTROLLER_NAME}:6817"] if controller_servers.empty?

            conf = "CPUs=#{cpu_count} RealMemory=#{real_memory_mb} Feature=one"
            gpus = gpu_count
            conf += " Gres=gpu:#{gpus}" if gpus > 0
            conf_servers = controller_servers.join(',')

            slurmd_unit = <<~UNIT
                [Unit]
                Description=Slurm node daemon
                After=munge.service network-online.target
                Wants=network-online.target
                Documentation=man:slurmd(8)

                [Service]
                Type=notify
                EnvironmentFile=-/etc/default/slurmd
                RuntimeDirectory=slurm
                RuntimeDirectoryMode=0755
                ExecStart=/usr/sbin/slurmd --systemd --conf-server #{conf_servers} -N #{hostname} -Z --conf "#{conf}"
                ExecReload=/bin/kill -HUP $MAINPID
                KillMode=process
                LimitNOFILE=131072
                LimitMEMLOCK=infinity
                LimitSTACK=infinity
                Delegate=yes
                TasksMax=infinity

                [Install]
                WantedBy=multi-user.target
            UNIT
            File.write('/etc/systemd/system/slurmd.service', slurmd_unit)
            bash('systemctl daemon-reload')
            bash('systemctl enable slurmd')
            bash('systemctl restart slurmd')
            bash('systemctl is-active slurmd')
        end

        def gpu_count
            stdout, _stderr, status = Open3.capture3('nvidia-smi --query-gpu=uuid' \
                                                     ' --format=csv,noheader')
            unless status.success?
                msg(:warn, 'nvidia-smi command failed, assuming 0 GPUs')
                return 0
            end
            stdout.lines.map(&:strip).reject(&:empty?).length
        rescue StandardError => e
            msg(:warn, "Error detecting GPU count: #{e.message}")
            0
        end

        def cpu_count
            bash('nproc').strip.to_i
        end

        def reserved_memory_mb
            return 512 unless defined?(ONEAPP_SLURM_RESERVED_MEMORY_MB)

            value = Integer(ONEAPP_SLURM_RESERVED_MEMORY_MB.to_s, 10)
            raise 'FATAL: ONEAPP_SLURM_RESERVED_MEMORY_MB cannot be negative' if value.negative?

            value
        rescue ArgumentError
            raise "FATAL: Invalid ONEAPP_SLURM_RESERVED_MEMORY_MB='#{ONEAPP_SLURM_RESERVED_MEMORY_MB}'"
        end

        def real_memory_mb
            meminfo = File.read('/proc/meminfo')
            unless meminfo =~ /^MemTotal:\s+(\d+)\s+kB/m
                raise 'FATAL: Unable to read MemTotal from /proc/meminfo'
            end

            total = ($1.to_i / 1024).to_i
            usable = total - reserved_memory_mb
            raise "FATAL: Reserved memory #{reserved_memory_mb} MiB leaves no usable Slurm memory" if usable <= 0

            usable
        end

    end

end
