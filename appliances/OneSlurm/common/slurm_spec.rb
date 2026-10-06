# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rspec'

require_relative 'slurm'

RSpec.describe OneSlurm::Slurm do
    subject(:helper) do
        Class.new do
            include OneSlurm::Slurm

            def bash(_command)
                '8'
            end

            def msg(*); end
        end.new
    end

    before do
        allow(File).to receive(:write)
        allow(FileUtils).to receive(:mkdir_p)
        allow(FileUtils).to receive(:chown_R)
        allow(FileUtils).to receive(:chmod)
    end

    it 'renders native primary and backup SlurmctldHost entries' do
        stub_const('ONEAPP_SLURM_HA_ENABLE', 'YES')
        stub_const('ONEAPP_SLURM_STATE_SAVE_LOCATION', '/mnt/slurm-state')
        stub_const('ONEAPP_SLURM_GPU_AUTODETECT', 'nvml')

        helper.write_controller_slurm_config(
            controller_hosts: [
                { name: 'slurm-one-controller-1', ip: '10.0.0.10' },
                { name: 'slurm-one-controller-2', ip: '10.0.0.11' }
            ],
            state_save_location: '/mnt/slurm-state'
        )

        expect(File).to have_received(:write).with(
            '/etc/slurm/slurm.conf',
            include(
                'SlurmctldHost=slurm-one-controller-1(10.0.0.10)',
                'SlurmctldHost=slurm-one-controller-2(10.0.0.11)',
                'StateSaveLocation=/mnt/slurm-state'
            )
        )
        expect(File).to have_received(:write).with('/etc/slurm/gres.conf', "AutoDetect=nvml\n")
    end

    it 'fails closed when HA uses local controller state' do
        stub_const('ONEAPP_SLURM_HA_ENABLE', 'YES')
        stub_const('ONEAPP_SLURM_STATE_SAVE_LOCATION', '/var/spool/slurmctld')

        expect do
            helper.write_controller_slurm_config(
                controller_hosts: [
                    { name: 'c1', ip: '10.0.0.10' },
                    { name: 'c2', ip: '10.0.0.11' }
                ]
            )
        end.to raise_error(/durable shared/)
    end

    it 'writes production cgroup constraints' do
        stub_const('ONEAPP_SLURM_HA_ENABLE', 'NO')
        helper.write_controller_slurm_config

        expect(File).to have_received(:write).with(
            '/etc/slurm/cgroup.conf',
            include(
                'CgroupPlugin=autodetect',
                'ConstrainCores=yes',
                'ConstrainRAMSpace=yes',
                'ConstrainSwapSpace=yes',
                'ConstrainDevices=yes'
            )
        )
    end

    it 'passes the complete ordered controller list to configless slurmd' do
        allow(helper).to receive(:cpu_count).and_return(16)
        allow(helper).to receive(:real_memory_mb).and_return(31_000)
        allow(helper).to receive(:gpu_count).and_return(2)
        allow(helper).to receive(:bash)

        helper.write_slurmd_unit(
            'worker-1',
            controller_servers: ['10.0.0.10:6817', '10.0.0.11:6817']
        )

        expect(File).to have_received(:write).with(
            '/etc/systemd/system/slurmd.service',
            include('--conf-server 10.0.0.10:6817,10.0.0.11:6817', 'Gres=gpu:2')
        )
    end

    it 'counts GPU UUID records rather than relying on index arithmetic' do
        status = double('process-status', success?: true)
        expect(Open3).to receive(:capture3)
            .with('nvidia-smi', '--query-gpu=uuid', '--format=csv,noheader')
            .and_return(["GPU-a\nGPU-b\n", '', status])

        expect(helper.gpu_count).to eq(2)
    end

    it 'reserves system memory before advertising RealMemory' do
        stub_const('ONEAPP_SLURM_RESERVED_MEMORY_MB', '1024')
        allow(File).to receive(:read).with('/proc/meminfo').and_return("MemTotal:       33554432 kB\n")

        expect(helper.real_memory_mb).to eq(31_744)
    end
end
