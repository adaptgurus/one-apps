# frozen_string_literal: true

# Shared Slurm configuration helpers: the controller writes the cluster
# configuration files, the worker builds its configless slurmd unit. The
# controller_ipv4 helper is used by both roles.
module OneSlurm

    module Slurm

        def controller_ipv4
            %w[ONEAPP_SLURM_SERVICE_IP ETH0_IP].each do |key|
                configured = ENV[key].to_s.strip
                return configured unless configured.empty? || configured == '0.0.0.0'
            end

            address = Socket.ip_address_list
                            .find { |a| a.ipv4? && !a.ipv4_loopback? }
            raise 'FATAL: No non-loopback IPv4 address found for Slurm controller' if address.nil?

            address.ip_address
        end

        def write_controller_slurm_config(controller_hosts: ['slurm-one-controller'],
                                          state_save_location: '/var/spool/slurmctld',
                                          cluster_name: 'one',
                                          max_node_count: 100,
                                          accounting_host: '',
                                          accounting_backup_host: '',
                                          accounting_port: '',
                                          constrain_cores: true,
                                          constrain_ram: true,
                                          constrain_swap: true,
                                          constrain_devices: true)
            controller_hosts = Array(controller_hosts).map(&:to_s).map(&:strip).reject(&:empty?).uniq
            raise 'FATAL: At least one Slurm controller host is required' if controller_hosts.empty?

            controller_lines = controller_hosts.map { |host| "SlurmctldHost=#{host}" }.join("\n")
            state_save_location = state_save_location.to_s.strip
            raise 'FATAL: StateSaveLocation must not be empty' if state_save_location.empty?

            cluster_name = cluster_name.to_s.strip
            unless cluster_name.match?(/\A[A-Za-z0-9._-]+\z/)
                raise 'FATAL: ClusterName must contain only letters, digits, dot, underscore or dash'
            end

            max_node_count = Integer(max_node_count)
            raise 'FATAL: MaxNodeCount must be positive' unless max_node_count.positive?

            accounting_config = ''
            unless accounting_host.to_s.strip.empty?
                accounting_config = <<~CONF
                    AccountingStorageType=accounting_storage/slurmdbd
                    AccountingStorageHost=#{accounting_host.to_s.strip}
                    #{accounting_backup_host.to_s.strip.empty? ? '' : "AccountingStorageBackupHost=#{accounting_backup_host.to_s.strip}"}
                    #{accounting_port.to_s.strip.empty? ? '' : "AccountingStoragePort=#{accounting_port.to_s.strip}"}
                    JobAcctGatherType=jobacct_gather/cgroup
                    JobAcctGatherFrequency=30
                CONF
            end

            infiniband_config = slurm_infiniband_enabled? ? <<~CONF : ''
                MpiDefault=pmix
                PropagateResourceLimitsExcept=MEMLOCK
            CONF

            # Create slurm.conf
            slurm_conf = <<~CONF
                ClusterName=#{cluster_name}
                #{controller_lines}
                AuthType=auth/munge
                ProctrackType=proctrack/cgroup
                SchedulerType=sched/backfill
                SelectType=select/cons_tres
                SelectTypeParameters=CR_Core_Memory
                GresTypes=gpu
                TaskPlugin=task/cgroup,task/affinity

                SlurmUser=slurm
                StateSaveLocation=#{state_save_location}
                SlurmdSpoolDir=/var/spool/slurmd

                SlurmctldPidFile=/var/run/slurm/slurmctld.pid
                SlurmdPidFile=/var/run/slurm/slurmd.pid

                SlurmctldParameters=enable_configless
                #{infiniband_config}
                #{accounting_config}

                MaxNodeCount=#{max_node_count}

                Nodeset=one Feature=one

                PartitionName=all  Nodes=ALL Default=yes
            CONF

            File.write('/etc/slurm/slurm.conf', slurm_conf)

            gres_conf = <<~CONF
                AutoDetect=nvidia
            CONF
            File.write('/etc/slurm/gres.conf', gres_conf)

            cgroup_conf = <<~CONF
                CgroupAutomount=yes
                ConstrainCores=#{constrain_cores ? 'yes' : 'no'}
                ConstrainRAMSpace=#{constrain_ram ? 'yes' : 'no'}
                ConstrainSwapSpace=#{constrain_swap ? 'yes' : 'no'}
                ConstrainDevices=#{constrain_devices ? 'yes' : 'no'}
            CONF
            File.write('/etc/slurm/cgroup.conf', cgroup_conf)

            # Create directories and set permissions
            FileUtils.mkdir_p('/var/spool/slurmd')
            FileUtils.mkdir_p(state_save_location)
            FileUtils.chown_R('slurm', 'slurm', '/var/spool/slurmd')
            FileUtils.chown_R('slurm', 'slurm', state_save_location)
            FileUtils.chmod(0700, '/var/spool/slurmd')
            FileUtils.chmod(0700, state_save_location)
        end

        def slurm_infiniband_enabled?
            return false unless defined?(ONEAPP_SLURM_INFINIBAND_ENABLE)

            ONEAPP_SLURM_INFINIBAND_ENABLE == true ||
                ONEAPP_SLURM_INFINIBAND_ENABLE.to_s.casecmp('YES').zero? ||
                ONEAPP_SLURM_INFINIBAND_ENABLE.to_s == '1'
        end

        def apply_slurmctld_config
            msg :info, 'Applying updated slurm.conf to running slurmctld'
            bash 'systemctl is-active slurmctld'
            bash 'scontrol reconfigure'
        rescue StandardError => e
            msg :warn, "Could not apply slurmctld reconfigure: #{e.message}"
        end

        def write_slurmd_unit(hostname, controller_hosts: ['slurm-one-controller'],
                              system_reserved_memory_mb: 0)
            controller_hosts = Array(controller_hosts).map(&:to_s).map(&:strip).reject(&:empty?).uniq
            raise 'FATAL: At least one Slurm controller host is required' if controller_hosts.empty?

            reserve = Integer(system_reserved_memory_mb)
            raise 'FATAL: System reserved memory cannot be negative' if reserve.negative?

            total_memory = real_memory_mb
            if reserve >= total_memory
                raise "FATAL: System reserved memory #{reserve} MiB must be less than total memory #{total_memory} MiB"
            end

            conf_server = controller_hosts.map { |host| "#{host}:6817" }.join(',')
            usable_memory = total_memory - reserve
            conf = "CPUs=#{cpu_count} RealMemory=#{usable_memory} Feature=one"
            gpus = gpu_count
            conf += " Gres=gpu:#{gpus}" if gpus > 0
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
                ExecStart=/usr/sbin/slurmd --systemd --conf-server #{conf_server} -N #{hostname} -Z --conf "#{conf}"
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
            stdout, _stderr, status = Open3.capture3('nvidia-smi --query-gpu=count' \
                                                     ' --format=csv,noheader')
            unless status.success?
                msg(:warn, 'nvidia-smi command failed, assuming 0 GPUs')
                return 0
            end
            stdout.strip.to_i
        rescue StandardError => e
            msg(:warn, "Error detecting GPU count: #{e.message}")
            0
        end

        def cpu_count
            bash('nproc').strip.to_i
        end

        def real_memory_mb
            meminfo = File.read('/proc/meminfo')
            if meminfo =~ /^MemTotal:\s+(\d+)\s+kB/m
                ($1.to_i / 1024).to_i
            else
                raise 'FATAL: Unable to read MemTotal from /proc/meminfo'
            end
        end

    end

end
