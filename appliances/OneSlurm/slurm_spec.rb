# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rspec'
require 'socket'

require_relative 'common/slurm'

class OneSlurmSpecHarness
    include OneSlurm::Slurm

    def bash(_command)
        ''
    end

    def msg(*_args); end
end

RSpec.describe OneSlurm::Slurm do
    subject(:harness) { OneSlurmSpecHarness.new }

    before do
        allow(File).to receive(:write)
        allow(FileUtils).to receive(:mkdir_p)
        allow(FileUtils).to receive(:chown_R)
        allow(FileUtils).to receive(:chmod)
        allow(harness).to receive(:slurm_infiniband_enabled?).and_return(false)
    end

    it 'writes native HA controllers, shared state and accounting configuration' do
        captured = {}
        allow(File).to receive(:write) do |path, content|
            captured[path] = content
        end

        harness.write_controller_slurm_config(
            controller_hosts: %w[slurm-one-controller-10 slurm-one-controller-11],
            state_save_location: '/var/lib/oneslurm/state',
            accounting_host: 'slurmdbd.internal',
            accounting_port: '6819'
        )

        slurm = captured.fetch('/etc/slurm/slurm.conf')
        expect(slurm).to include('SlurmctldHost=slurm-one-controller-10')
        expect(slurm).to include('SlurmctldHost=slurm-one-controller-11')
        expect(slurm).to include('StateSaveLocation=/var/lib/oneslurm/state')
        expect(slurm).to include('AccountingStorageType=accounting_storage/slurmdbd')
        expect(slurm).to include('AccountingStorageHost=slurmdbd.internal')
        expect(slurm).to include('AccountingStoragePort=6819')

        cgroup = captured.fetch('/etc/slurm/cgroup.conf')
        expect(cgroup).to include('ConstrainCores=yes')
        expect(cgroup).to include('ConstrainRAMSpace=yes')
        expect(cgroup).to include('ConstrainSwapSpace=yes')
        expect(cgroup).to include('ConstrainDevices=yes')
    end

    it 'keeps the legacy single-controller default' do
        captured = {}
        allow(File).to receive(:write) do |path, content|
            captured[path] = content
        end

        harness.write_controller_slurm_config

        slurm = captured.fetch('/etc/slurm/slurm.conf')
        expect(slurm.scan('SlurmctldHost=').length).to eq(1)
        expect(slurm).to include('SlurmctldHost=slurm-one-controller')
        expect(slurm).to include('StateSaveLocation=/var/spool/slurmctld')
        expect(slurm).not_to include('AccountingStorageType=')
    end

    it 'passes an ordered controller list to configless slurmd' do
        unit = nil
        allow(File).to receive(:write) do |path, content|
            unit = content if path == '/etc/systemd/system/slurmd.service'
        end
        allow(harness).to receive(:cpu_count).and_return(16)
        allow(harness).to receive(:real_memory_mb).and_return(32768)
        allow(harness).to receive(:gpu_count).and_return(2)

        harness.write_slurmd_unit(
            'slurm-one-worker-20',
            controller_hosts: %w[slurm-one-controller-10 slurm-one-controller-11]
        )

        expect(unit).to include('--conf-server slurm-one-controller-10:6817,slurm-one-controller-11:6817')
        expect(unit).to include('Gres=gpu:2')
    end

    it 'rejects an empty controller list' do
        expect do
            harness.write_controller_slurm_config(controller_hosts: [])
        end.to raise_error(/At least one Slurm controller host/)
    end
end
