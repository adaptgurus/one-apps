# frozen_string_literal: true

require 'fileutils'
require 'rspec'

require_relative 'accounting'

RSpec.describe OneSlurm::Accounting do
    subject(:helper) do
        Class.new do
            include OneSlurm::Accounting

            def bash(_command)
                ''
            end
        end.new
    end

    before do
        stub_const('ONEAPP_SLURM_ACCOUNTING_ENABLE', 'YES')
        stub_const('ONEAPP_SLURM_ACCOUNTING_PORT', '6819')
        stub_const('ONEAPP_SLURM_ACCOUNTING_DB_HOST', 'db.internal')
        stub_const('ONEAPP_SLURM_ACCOUNTING_DB_PORT', '3306')
        stub_const('ONEAPP_SLURM_ACCOUNTING_DB_NAME', 'slurm_acct_db')
        stub_const('ONEAPP_SLURM_ACCOUNTING_DB_USER', 'slurm')
        stub_const('ONEAPP_SLURM_ACCOUNTING_DB_PASSWORD', 'test-only-secret')
        stub_const('ONEAPP_SLURM_ACCOUNTING_DB_PASSWORD_FILE', '')
        allow(File).to receive(:write)
        allow(FileUtils).to receive(:mkdir_p)
        allow(FileUtils).to receive(:chown)
        allow(FileUtils).to receive(:chmod)
    end

    it 'renders primary and backup SlurmDBD endpoints into slurm.conf accounting settings' do
        conf = helper.slurm_accounting_config([
            { name: 'slurm-one-controller-1' },
            { name: 'slurm-one-controller-2' }
        ])

        expect(conf).to include('AccountingStorageType=accounting_storage/slurmdbd')
        expect(conf).to include('AccountingStorageHost=slurm-one-controller-1')
        expect(conf).to include('AccountingStorageBackupHost=slurm-one-controller-2')
        expect(conf).to include('AccountingStorageTRES=gres/gpu')
    end

    it 'writes slurmdbd.conf with restrictive permissions' do
        helper.write_slurmdbd_config([
            { name: 'slurm-one-controller-1' },
            { name: 'slurm-one-controller-2' }
        ])

        expect(File).to have_received(:write).with(
            '/etc/slurm/slurmdbd.conf',
            include(
                'DbdHost=slurm-one-controller-1',
                'DbdBackupHost=slurm-one-controller-2',
                'StorageHost=db.internal',
                'StorageLoc=slurm_acct_db'
            )
        )
        expect(FileUtils).to have_received(:chmod).with(0600, '/etc/slurm/slurmdbd.conf')
    end

    it 'fails closed when accounting credentials are incomplete' do
        stub_const('ONEAPP_SLURM_ACCOUNTING_DB_PASSWORD', '')

        expect { helper.validate_accounting_config! }.to raise_error(/password is required/)
    end

    it 'does nothing when accounting is disabled' do
        stub_const('ONEAPP_SLURM_ACCOUNTING_ENABLE', 'NO')

        expect(helper.slurm_accounting_config([{ name: 'c1' }])).to eq('')
    end
end
