# frozen_string_literal: true

require 'rspec'

require_relative 'worker/main'

RSpec.describe Service::SlurmWorker do
    def controller_vm(id:, ip:, key: '', ready: 'YES', name: '')
        {
            'VM' => {
                'ID' => id.to_s,
                'USER_TEMPLATE' => {
                    'READY' => ready,
                    'SLURM_MUNGE_KEY' => key,
                    'SLURM_CONTROLLER_NAME' => name
                },
                'TEMPLATE' => {
                    'NIC' => {
                        'NETWORK' => 'service-net',
                        'IP' => ip
                    }
                }
            }
        }
    end

    before do
        allow(described_class).to receive(:msg)
    end

    it 'returns an ordered READY controller set with one shared MUNGE key' do
        first = controller_vm(id: 10, ip: '10.0.0.10', key: 'shared-key')
        second = controller_vm(id: 11, ip: '10.0.0.11', key: 'shared-key')
        allow(described_class).to receive(:role_vms_show)
            .with('controller').and_return([second, first])

        controllers, key, = described_class.discover_controllers(0, 0)

        expect(controllers.map { |controller| controller['vmid'] }).to eq(%w[10 11])
        expect(controllers.map { |controller| controller['name'] }).to eq(
            %w[slurm-one-controller-10 slurm-one-controller-11]
        )
        expect(key).to eq('shared-key')
    end

    it 'fails closed when READY controllers publish different MUNGE keys' do
        first = controller_vm(id: 10, ip: '10.0.0.10', key: 'key-a')
        second = controller_vm(id: 11, ip: '10.0.0.11', key: 'key-b')
        allow(described_class).to receive(:role_vms_show)
            .with('controller').and_return([first, second])

        expect do
            described_class.discover_controllers(0, 0)
        end.to raise_error(/FATAL: READY Slurm controllers published inconsistent MUNGE keys/)
    end

    it 'uses the configured cluster secret without requiring it in OneGate metadata' do
        stub_const('ONEAPP_SLURM_MUNGE_KEY_BASE64', 'configured-key')
        first = controller_vm(id: 10, ip: '10.0.0.10')
        second = controller_vm(id: 11, ip: '10.0.0.11')
        allow(described_class).to receive(:role_vms_show)
            .with('controller').and_return([first, second])

        controllers, key, = described_class.discover_controllers(0, 0)

        expect(controllers.length).to eq(2)
        expect(key).to eq('configured-key')
    end
end
