# frozen_string_literal: true

require 'rspec'
require_relative 'main'

RSpec.describe Service::OneKS do
  after do
    described_class.stop_onegate_heartbeat
  end

  it 'emits bounded heartbeat metadata without bootstrap secrets' do
    emitted = []
    allow(described_class).to receive(:onegate_vm_update) do |data|
      emitted << data
      true
    end

    described_class.start_onegate_heartbeat
    described_class.report_onegate_state('PROVISIONING_CP', 'NONE')

    payload = emitted.last
    expect(payload).to include('ONEKS_STATE=PROVISIONING_CP', 'ONEKS_ERROR_CODE=NONE')
    expect(payload.grep(/\AONEKS_HEARTBEAT_AT=\d+\z/).size).to eq(1)
    expect(payload.grep(/\AONEKS_HEARTBEAT_SEQ=\d+\z/).size).to eq(1)
    expect(payload.join("\n")).not_to include('ONE_AUTH', 'KUBECONFIG', 'TOKEN')
  end

  it 'advances the sequence on each explicit phase heartbeat' do
    emitted = []
    allow(described_class).to receive(:onegate_vm_update) do |data|
      emitted << data
      true
    end

    described_class.start_onegate_heartbeat
    described_class.report_onegate_state('PROVISIONING_MGMT')
    described_class.report_onegate_state('PROVISIONING_CP')

    sequences = emitted.map do |payload|
      payload.find { |field| field.start_with?('ONEKS_HEARTBEAT_SEQ=') }.split('=').last.to_i
    end
    expect(sequences).to eq(sequences.sort)
    expect(sequences.uniq.length).to eq(sequences.length)
  end

  it 'stops the periodic heartbeat deterministically' do
    allow(described_class).to receive(:onegate_vm_update).and_return(true)

    described_class.start_onegate_heartbeat
    thread = described_class.instance_variable_get(:@heartbeat_thread)
    expect(thread).to be_alive

    described_class.stop_onegate_heartbeat
    expect(described_class.instance_variable_get(:@heartbeat_thread)).to be_nil
    expect(thread).not_to be_alive
  end

  it 'uses argv-based OneGate invocation instead of shell interpolation' do
    status = double('status', success?: true)
    expect(Open3).to receive(:capture3).with(
      'onegate', 'vm', 'update', '--data', "ONEKS_STATE=RUNNING\nONEKS_ERROR_CODE=NONE"
    ).and_return(['', '', status])

    expect(
      described_class.onegate_vm_update(['ONEKS_STATE=RUNNING', 'ONEKS_ERROR_CODE=NONE'])
    ).to be(true)
  end
end
