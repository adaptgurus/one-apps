# frozen_string_literal: true

module OneSlurm
    module Accounting
        def accounting_enabled?
            return false unless defined?(ONEAPP_SLURM_ACCOUNTING_ENABLE)

            %w[1 true yes on].include?(ONEAPP_SLURM_ACCOUNTING_ENABLE.to_s.strip.downcase)
        end

        def accounting_password
            if defined?(ONEAPP_SLURM_ACCOUNTING_DB_PASSWORD_FILE)
                path = ONEAPP_SLURM_ACCOUNTING_DB_PASSWORD_FILE.to_s.strip
                unless path.empty?
                    raise "FATAL: Slurm accounting password file '#{path}' does not exist" unless File.file?(path)

                    value = File.read(path).strip
                    raise 'FATAL: Slurm accounting password file is empty' if value.empty?
                    return value
                end
            end

            value = defined?(ONEAPP_SLURM_ACCOUNTING_DB_PASSWORD) ?
                    ONEAPP_SLURM_ACCOUNTING_DB_PASSWORD.to_s : ''
            value = value.strip
            raise 'FATAL: Slurm accounting database password is required' if value.empty?

            value
        end

        def validate_accounting_config!
            return unless accounting_enabled?

            required = {
                'ONEAPP_SLURM_ACCOUNTING_DB_HOST' => ONEAPP_SLURM_ACCOUNTING_DB_HOST,
                'ONEAPP_SLURM_ACCOUNTING_DB_NAME' => ONEAPP_SLURM_ACCOUNTING_DB_NAME,
                'ONEAPP_SLURM_ACCOUNTING_DB_USER' => ONEAPP_SLURM_ACCOUNTING_DB_USER
            }
            required.each do |name, value|
                raise "FATAL: #{name} is required when Slurm accounting is enabled" if value.to_s.strip.empty?
            end
            Integer(ONEAPP_SLURM_ACCOUNTING_DB_PORT.to_s, 10)
            Integer(ONEAPP_SLURM_ACCOUNTING_PORT.to_s, 10)
            accounting_password
        rescue ArgumentError
            raise 'FATAL: Slurm accounting database/listener ports must be integers'
        end

        def slurm_accounting_config(controller_hosts)
            return '' unless accounting_enabled?

            validate_accounting_config!
            controllers = Array(controller_hosts)
            raise 'FATAL: Slurm accounting requires at least one controller host' if controllers.empty?

            primary = controllers.first[:name] || controllers.first['name']
            backup = if controllers.length > 1
                         controllers[1][:name] || controllers[1]['name']
                     end
            backup_line = backup.to_s.empty? ? '' : "AccountingStorageBackupHost=#{backup}\n"

            <<~CONF
                AccountingStorageType=accounting_storage/slurmdbd
                AccountingStorageHost=#{primary}
                #{backup_line}AccountingStoragePort=#{ONEAPP_SLURM_ACCOUNTING_PORT}
                AccountingStorageTRES=gres/gpu
                JobAcctGatherType=jobacct_gather/cgroup
                JobAcctGatherFrequency=30
            CONF
        end

        def write_slurmdbd_config(controller_hosts)
            return unless accounting_enabled?

            validate_accounting_config!
            controllers = Array(controller_hosts)
            raise 'FATAL: SlurmDBD requires at least one controller host' if controllers.empty?

            primary = controllers.first[:name] || controllers.first['name']
            backup = if controllers.length > 1
                         controllers[1][:name] || controllers[1]['name']
                     end

            backup_line = backup.to_s.empty? ? '' : "DbdBackupHost=#{backup}\n"
            conf = <<~CONF
                AuthType=auth/munge
                DbdHost=#{primary}
                #{backup_line}DbdPort=#{ONEAPP_SLURM_ACCOUNTING_PORT}
                SlurmUser=slurm
                PidFile=/run/slurmdbd/slurmdbd.pid
                LogFile=/var/log/slurm/slurmdbd.log
                StorageType=accounting_storage/mysql
                StorageHost=#{ONEAPP_SLURM_ACCOUNTING_DB_HOST}
                StoragePort=#{ONEAPP_SLURM_ACCOUNTING_DB_PORT}
                StorageLoc=#{ONEAPP_SLURM_ACCOUNTING_DB_NAME}
                StorageUser=#{ONEAPP_SLURM_ACCOUNTING_DB_USER}
                StoragePass=#{accounting_password}
            CONF

            FileUtils.mkdir_p('/var/log/slurm')
            FileUtils.chown('slurm', 'slurm', '/var/log/slurm')
            File.write('/etc/slurm/slurmdbd.conf', conf)
            FileUtils.chown('slurm', 'slurm', '/etc/slurm/slurmdbd.conf')
            FileUtils.chmod(0600, '/etc/slurm/slurmdbd.conf')
        end

        def enable_slurmdbd
            return unless accounting_enabled?

            bash 'systemctl enable slurmdbd'
            bash 'systemctl restart slurmdbd'
            bash 'systemctl is-active slurmdbd'
        end

        def ensure_accounting_cluster
            return unless accounting_enabled?

            existing = bash("sacctmgr -nP show cluster name=one format=Cluster 2>/dev/null || true").to_s
            return if existing.lines.map(&:strip).include?('one')

            bash 'sacctmgr -i add cluster one'
        end
    end
end
