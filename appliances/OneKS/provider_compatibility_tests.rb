# frozen_string_literal: true

require 'rspec'
require 'tmpdir'
require 'yaml'
require_relative 'main'

RSpec.describe Service::OneKS do
  it 'accepts only the exact live-qualified provider set' do
    expect(described_class.validate_provider_contracts!).to be(true)

    expect do
      described_class.validate_provider_contracts!(capi_version: '1.13.6')
    end.to raise_error(/Unqualified OneKS provider set/)

    expect do
      described_class.validate_provider_contracts!(caprke2_version: '0.25.3')
    end.to raise_error(/Unqualified OneKS provider set/)

    expect do
      described_class.validate_provider_contracts!(capone_version: '0.1.9')
    end.to raise_error(/Unqualified OneKS provider set/)

    expect do
      described_class.validate_provider_contracts!(capone_contract: 'v1beta2')
    end.to raise_error(/Unqualified OneKS provider set/)
  end

  it 'reports management provider initialization failures explicitly' do
    stub_const('ONEKS_CLUSTER_SPEC', Base64.strict_encode64("apiVersion: v1\nkind: List\nitems: []\n"))
    reported = []
    allow(described_class).to receive(:start_onegate_heartbeat)
    allow(described_class).to receive(:stop_onegate_heartbeat)
    allow(described_class).to receive(:bash).and_return('')
    allow(described_class).to receive(:report_onegate_state) do |state, code = 'NONE'|
      reported << [state, code]
    end
    allow(described_class).to receive(:initialize_providers)
      .with(ONEKS_MGMT_KUBECONFIG_PATH)
      .and_raise('metadata validation failed')

    expect { described_class.configure }.to raise_error(SystemExit)
    expect(reported).to include(['PROVISIONING_FAILURE', 'MGMT_PROVIDER_INIT_FAILED'])
    expect(reported).not_to include(['PROVISIONING_FAILURE', 'PROVISIONING_EXCEPTION'])
  end

  it 'reports workload provider initialization failures explicitly' do
    stub_const('ONEKS_CLUSTER_SPEC', Base64.strict_encode64("apiVersion: v1\nkind: List\nitems: []\n"))
    stub_const('ONEKS_CNI_DAEMONSET', '')
    reported = []
    provider_calls = 0

    allow(described_class).to receive(:start_onegate_heartbeat)
    allow(described_class).to receive(:stop_onegate_heartbeat)
    allow(described_class).to receive(:bash).and_return('')
    allow(described_class).to receive(:begin_retry?).and_return(true)
    allow(described_class).to receive(:report_onegate_state) do |state, code = 'NONE'|
      reported << [state, code]
    end
    allow(described_class).to receive(:initialize_providers) do |_kubeconfig|
      provider_calls += 1
      raise 'workload provider validation failed' if provider_calls == 2
      true
    end

    expect { described_class.configure }.to raise_error(SystemExit)
    expect(provider_calls).to eq(2)
    expect(reported).to include(['PIVOTING_FAILURE', 'WKLD_PROVIDER_INIT_FAILED'])
    expect(reported).not_to include(['PIVOTING_FAILURE', 'PIVOT_EXCEPTION'])
  end

  it 'rejects CAPONE metadata that clusterctl 1.11+ rejects' do
    metadata = {
      'apiVersion' => 'clusterctl.cluster.x-k8s.io/v1alpha3',
      'releaseSeries' => [
        {'major' => 0, 'minor' => 1, 'contract' => 'v1beta1'}
      ]
    }

    expect do
      described_class.validate_provider_metadata!(metadata, 'opennebula:v0.1.8')
    end.to raise_error(/kind.*Metadata/i)
  end

  it 'creates a strict-valid local metadata override for the pinned CAPONE release' do
    Dir.mktmpdir do |dir|
      described_class.prepare_provider_overrides(dir)

      path = File.join(
        dir,
        'infrastructure-opennebula',
        "v#{ONEKS_CAPONE_VERSION}",
        'metadata.yaml'
      )
      expect(File).to exist(path)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)

      metadata = YAML.safe_load(File.read(path))
      expect(metadata.fetch('apiVersion')).to eq('clusterctl.cluster.x-k8s.io/v1alpha3')
      expect(metadata.fetch('kind')).to eq('Metadata')
      expect(metadata.fetch('releaseSeries')).to include(
        {'major' => 0, 'minor' => 1, 'contract' => 'v1beta1'}
      )
      expect do
        described_class.validate_provider_metadata!(
          metadata,
          "opennebula:v#{ONEKS_CAPONE_VERSION}"
        )
      end.not_to raise_error
    end
  end

  it 'passes the override folder to clusterctl before provider initialization' do
    Dir.mktmpdir do |dir|
      script = nil
      config_body = nil

      allow(described_class).to receive(:bash) do |value|
        script = value
        match = value.match(/--config (\S+)/)
        config_body = File.read(match[1]) if match
        ''
      end
      allow(described_class).to receive(:qualify_provider_startup)

      described_class.initialize_providers('/run/qualification.kubeconfig', overrides_path: dir)

      expect(config_body).to include("overridesFolder: #{dir}")
      expect(script).to include('--infrastructure=opennebula:v0.1.8')
    end
  end
end
