# frozen_string_literal: true

begin
    require '/etc/one-appliance/lib/helpers'
rescue LoadError
    require_relative '../../lib/helpers'
end

require 'fileutils'
require 'shellwords'
require 'socket'

require_relative '../common/onegate'
require_relative '../common/ldap'
require_relative '../common/munge'
require_relative 'config'

module Service

    # SlurmDBD accounting service implementation.
    module SlurmAccounting

        extend self

        include OneSlurm::Ldap
        include OneSlurm::Munge

        DEPENDS_ON = []

        def install
            msg :info, 'SlurmAccounting::install'
            bash <<~SCRIPT
                export DEBIAN_FRONTEND=noninteractive
                apt update
                apt install -y munge libmunge-dev slurmdbd slurm-client \
                    slurm-wlm-basic-plugins slurm-wlm-mysql-plugin \
                    sssd sssd-ldap libnss-sss libpam-sss ldap-utils
            SCRIPT
            bash 'systemctl disable slurmdbd || true'
            msg :info, 'Installation completed successfully'
        end

        def current_vm_id
            vm = onegate_vm_show
            id = vm.dig('VM', 'ID').to_s
            raise 'FATAL: Could not determine current accounting VM ID from OneGate' if id.empty?

            id
        end

        def accounting_records
            vms = role_vms_show('accounting')
            raise 'FATAL: No accounting VMs found in OneGate service' if vms.empty?

            multi = vms.length > 1
            vms.map do |vm|
                vmid = vm.dig('VM', 'ID').to_s
                raise 'FATAL: Accounting VM is missing ID' if vmid.empty?

                ip = vm_nic_ipv4(vm, preferred_network: ONEAPP_SLURM_SERVICE_NETWORK)
                raise "FATAL: Accounting VM #{vmid} has no usable IPv4 address" if ip.empty?

                {
                    vmid: vmid,
                    name: multi ? "slurm-one-dbd-#{vmid}" : 'slurm-one-dbd',
                    ip: ip
                }
            end.sort_by { |record| record[:vmid].to_i }
        end

        def configure_identity(records)
            vmid = current_vm_id
            self_record = records.find { |record| record[:vmid] == vmid }
            raise "FATAL: Current VM #{vmid} is not present in accounting role" if self_record.nil?

            hostname = Socket.gethostname.split('.').first
            if hostname != self_record[:name]
                bash "hostnamectl set-hostname #{Shellwords.escape(self_record[:name])}"
            end

            hosts = File.read('/etc/hosts')
            File.open('/etc/hosts', 'a') do |file_handle|
                records.each do |record|
                    entry = "#{record[:ip]}\t#{record[:name]}"
                    file_handle.puts entry unless hosts.include?(entry)
                end
            end

            self_record
        end

        def validate_database_config!
            host = ONEAPP_SLURM_DB_HOST.to_s.strip
            user = ONEAPP_SLURM_DB_USER.to_s.strip
            password = ONEAPP_SLURM_DB_PASSWORD.to_s
            db_name = ONEAPP_SLURM_DB_NAME.to_s.strip

            raise 'FATAL: ONEAPP_SLURM_DB_HOST is required' if host.empty?
            raise 'FATAL: ONEAPP_SLURM_DB_USER is required' if user.empty?
            raise 'FATAL: ONEAPP_SLURM_DB_PASSWORD is required' if password.empty?
            raise 'FATAL: ONEAPP_SLURM_DB_NAME is required' if db_name.empty?
            if password.include?('#') || password.include?("\n") || password.include?("\r")
                raise 'FATAL: SlurmDBD database password contains unsupported characters'
            end
        end

        def obtain_munge_key
            configured = ONEAPP_SLURM_MUNGE_KEY_BASE64.to_s.strip
            return configured unless configured.empty?

            with_retries(attempts: 20, delay: 10,
                         msg: 'Waiting for controller MUNGE bootstrap data') do
                controllers = role_vms_show('controller')
                keys = controllers.map do |vm|
                    vm.dig('VM', 'USER_TEMPLATE', 'SLURM_MUNGE_KEY').to_s
                end.reject(&:empty?).uniq

                raise 'Controller has not published MUNGE bootstrap data yet' if keys.empty?
                raise 'FATAL: Controllers published inconsistent MUNGE keys' if keys.length != 1

                keys.first
            end
        end

        def configure_munge
            key = obtain_munge_key
            return if munge_key_generated? && munge_key_base64 == key

            install_munge_key(key)
            FileUtils.touch(OneSlurm::Munge::MUNGE_KEY_FLAG)
        end

        def configure_external_identity
            url = ONEAPP_LDAP_URL.to_s.strip
            domain = ONEAPP_LDAP_DOMAIN.to_s.strip
            if url.empty? || domain.empty?
                msg :info, 'No external LDAP configured for SlurmDBD identity resolution'
                return
            end

            apply_sssd_ldap_client(
                url,
                domain,
                ONEAPP_LDAP_BIND_USER.to_s,
                ONEAPP_LDAP_BIND_PASSWORD.to_s
            )
        end

        def write_slurmdbd_config(records)
            primary = records.first
            backup = records[1]

            db_backup = ONEAPP_SLURM_DB_BACKUP_HOST.to_s.strip
            db_password = ONEAPP_SLURM_DB_PASSWORD.to_s

            conf = <<~CONF
                AuthType=auth/munge
                DbdHost=#{primary[:name]}
                #{backup.nil? ? '' : "DbdBackupHost=#{backup[:name]}"}
                DbdPort=#{ONEAPP_SLURM_DBD_PORT}
                SlurmUser=slurm

                StorageType=accounting_storage/mysql
                StorageHost=#{ONEAPP_SLURM_DB_HOST}
                #{db_backup.empty? ? '' : "StorageBackupHost=#{db_backup}"}
                StoragePort=#{ONEAPP_SLURM_DB_PORT}
                StorageLoc=#{ONEAPP_SLURM_DB_NAME}
                StorageUser=#{ONEAPP_SLURM_DB_USER}
                StoragePass=#{db_password}

                ArchiveDir=#{ONEAPP_SLURM_ARCHIVE_DIR}
                ArchiveEvents=yes
                ArchiveJobs=yes
                ArchiveResvs=yes
                ArchiveTXN=yes
                ArchiveUsage=yes
                PurgeJobAfter=#{ONEAPP_SLURM_PURGE_JOB_AFTER}
                PurgeTXNAfter=#{ONEAPP_SLURM_PURGE_TXN_AFTER}
                PurgeUsageAfter=#{ONEAPP_SLURM_PURGE_USAGE_AFTER}
            CONF

            FileUtils.mkdir_p('/etc/slurm')
            File.write('/etc/slurm/slurmdbd.conf', conf)
            FileUtils.chown('slurm', 'slurm', '/etc/slurm/slurmdbd.conf')
            FileUtils.chmod(0o600, '/etc/slurm/slurmdbd.conf')

            FileUtils.mkdir_p(ONEAPP_SLURM_ARCHIVE_DIR)
            FileUtils.chown_R('slurm', 'slurm', ONEAPP_SLURM_ARCHIVE_DIR)
            FileUtils.chmod(0o700, ONEAPP_SLURM_ARCHIVE_DIR)
        end

        def ensure_service
            with_retries(attempts: 10, delay: 10,
                         msg: 'Waiting for SlurmDBD/database readiness') do
                bash 'systemctl enable slurmdbd'
                bash 'systemctl restart slurmdbd'
                bash 'systemctl is-active slurmdbd'
            end
        end

        def ensure_cluster_registered(self_record, records)
            return unless self_record[:vmid] == records.first[:vmid]

            cluster = ONEAPP_SLURM_CLUSTER_NAME.to_s.strip
            unless cluster.match?(/\A[A-Za-z0-9._-]+\z/)
                raise 'FATAL: ClusterName must contain only letters, digits, dot, underscore or dash'
            end

            escaped = Shellwords.escape(cluster)
            with_retries(attempts: 10, delay: 10,
                         msg: 'Registering cluster in SlurmDBD') do
                existing = bash(
                    "sacctmgr -n -P show cluster #{escaped} format=Cluster",
                    chomp: true
                )
                bash "sacctmgr -i add cluster #{escaped}" if existing.strip.empty?
            end
        end

        def publish_ready(self_record)
            with_retries(msg: 'Publishing SlurmDBD readiness to OneGate') do
                onegate_vm_update [
                    "SLURMDBD_NAME=#{self_record[:name]}",
                    'READY=YES'
                ]
            end
        end

        def configure
            msg :info, 'SlurmAccounting::configure'
            validate_database_config!

            records = accounting_records
            self_record = configure_identity(records)
            configure_munge
            configure_external_identity
            write_slurmdbd_config(records)
            ensure_service
            ensure_cluster_registered(self_record, records)
            publish_ready(self_record)

            msg :info, 'Configuration completed successfully'
        end

        def bootstrap
            msg :info, 'SlurmAccounting::bootstrap'
            msg :info, 'Bootstrap completed successfully'
        end

    end
end
