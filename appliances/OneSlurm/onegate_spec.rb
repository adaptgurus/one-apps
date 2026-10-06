# frozen_string_literal: true

require 'json'
require 'rspec'

require_relative 'common/onegate'

RSpec.describe 'vm_nic_ipv4' do
    let(:vm) do
        {
            'VM' => {
                'TEMPLATE' => {
                    'NIC' => [
                        { 'NAME' => 'backup', 'NETWORK' => 'backup-net', 'IP' => '10.20.0.8' },
                        { 'NAME' => 'service', 'NETWORK' => 'service-net', 'IP' => '10.10.0.8' }
                    ]
                }
            }
        }
    end

    it 'selects the explicitly requested service network' do
        expect(vm_nic_ipv4(vm, preferred_network: 'service-net')).to eq('10.10.0.8')
    end

    it 'retains first-NIC compatibility when no network is requested' do
        expect(vm_nic_ipv4(vm)).to eq('10.20.0.8')
    end

    it 'falls back when the requested network is absent' do
        expect(vm_nic_ipv4(vm, preferred_network: 'missing')).to eq('10.20.0.8')
    end
end
