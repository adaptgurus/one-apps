# frozen_string_literal: true
require 'rspec'
require 'tmpdir'
require_relative 'main'
include Service

RSpec.describe Service::OneKS do
  it 'reads contextualization boolean values through the real env helper' do
    %w[YES NO].each do |value|
      out, err, status = Open3.capture3({'ONEAPP_ONEKS_LEADER_ELECTION_GRACE' => value},
        RbConfig.ruby, '-r', File.expand_path('main', __dir__),
        '-e', 'puts ONEKS_LEADER_ELECTION_GRACE.inspect')
      expect(status.success?).to be(true), err
      expect(out.strip).to eq(value == 'YES' ? 'true' : 'false')
    end
  end
  [false, true].each do |grace|
    it "keeps leader tuning explicitly scoped (enabled=#{grace})" do
      stub_const('ONEKS_LEADER_ELECTION_GRACE', grace)
      namespaces = %w[capi-system capone-system rke2-bootstrap-system rke2-control-plane-system]
      deployments = namespaces.map do |ns|
        {'metadata' => {'name' => 'manager', 'namespace' => ns},
         'spec' => {'template' => {'spec' => {'containers' => [
           {'name' => 'manager', 'args' => ['--leader-elect'],
            'livenessProbe' => {'httpGet' => {'path' => '/healthz', 'port' => 9440}}}
         ]}}}}
      end
      status = double('status', success?: true)
      patches = []
      allow(Open3).to receive(:capture3) do |*argv, **opts|
        if argv.include?('get')
          [JSON.generate('items' => deployments), '', status]
        else
          patches << [argv[argv.index('-n') + 1], JSON.parse(opts[:stdin_data])] if argv.include?('patch')
          ['', '', status]
        end
      end
      described_class.qualify_provider_startup('/run/fixture.kubeconfig')
      expect(patches.size).to eq(4)
      patches.each do |ns, patch|
        container = patch.dig('spec', 'template', 'spec', 'containers', 0)
        args = container['args']
        expect(container.dig('livenessProbe', 'timeoutSeconds')).to eq(grace ? 15 : 5)
        expect(container.dig('livenessProbe', 'failureThreshold')).to eq(6) if grace
        if grace && ns != 'capone-system'
          expect(args).to include('--leader-elect', '--leader-elect-lease-duration=60s',
                                  '--leader-elect-renew-deadline=40s', '--leader-elect-retry-period=10s')
        else
          expect(args).to be_nil
        end
      end
    end
  end
  it 'installs verified tools and caches an image without baking a management cluster' do
    scripts = []
    allow(described_class).to receive(:bash) { |script| scripts << script; '' }
    described_class.install
    combined = scripts.join("\n")
    expect(combined.scan('sha256sum -c -').length).to eq(3)
    expect(combined).to include(ONEKS_KIND_IMAGE)
    expect(combined).not_to include('kind create cluster', 'get kubeconfig', 'clusterctl init')
  end
  it 'accepts only the explicitly qualified provider contract skew' do
    expect(described_class.validate_provider_contracts!).to be(true)
    expect do
      described_class.validate_provider_contracts!(
        capi_version: '1.16.0',
        capi_contract: 'v1beta2',
        caprke2_contract: 'v1beta2',
        capone_contract: 'v1beta1'
      )
    end.to raise_error(/CAPONE v1beta1 contract is no longer compatible/)
    expect do
      described_class.validate_provider_contracts!(
        capi_version: '1.13.5',
        capi_contract: 'v1beta2',
        caprke2_contract: 'v1beta1',
        capone_contract: 'v1beta1'
      )
    end.to raise_error(/CAPRKE2 contract must match/)
  end

  it 'builds a local CAPONE repository with clusterctl 1.11+ metadata' do
    Dir.mktmpdir('oneks-provider-test') do |dir|
      source = File.join(dir, 'source-components.yaml')
      File.write(source, "apiVersion: v1\nkind: List\nitems: []\n")
      repository = File.join(dir, 'providers')
      stub_const('ONEKS_PROVIDER_REPOSITORY_PATH', repository)
      stub_const('ONEKS_CAPONE_COMPONENTS_SOURCE', source)

      components = described_class.prepare_capone_repository
      metadata = File.join(File.dirname(components), 'metadata.yaml')

      expect(components).to eq(
        File.join(repository, 'infrastructure-opennebula', 'v0.1.8',
                  'infrastructure-components.yaml')
      )
      expect(File.read(components)).to eq(File.read(source))
      expect(File.read(metadata)).to include(
        'apiVersion: clusterctl.cluster.x-k8s.io/v1alpha3',
        'kind: Metadata',
        'contract: v1beta1'
      )
    end
  end

  it 'pins all three native provider versions and the local CAPONE repository' do
    script = nil
    timeout_config = nil
    capone_components = '/opt/oneks/providers/infrastructure-opennebula/v0.1.8/infrastructure-components.yaml'
    allow(described_class).to receive(:prepare_capone_repository).and_return(capone_components)
    allow(described_class).to receive(:bash) do |value|
      script = value
      timeout_config = File.read(value.match(/--config (\S+)/)[1])
      ''
    end
    expect(described_class).to receive(:qualify_provider_startup).with('/run/qualification.kubeconfig')
    described_class.initialize_providers('/run/qualification.kubeconfig')
    expect(timeout_config).to include(
      "cert-manager:\n  timeout: #{ONEKS_READY_TIMEOUT_SECONDS}s\n",
      'name: opennebula',
      "url: #{capone_components}",
      'type: InfrastructureProvider'
    )
    expect(script).to include('--core=cluster-api:v1.13.5', '--bootstrap=rke2:v0.25.2',
                             '--control-plane=rke2:v0.25.2', '--infrastructure=opennebula:v0.1.8')
  end
  it 'passes the specification through stdin without shell interpolation' do
    spec = "apiVersion: v1\nkind: Secret\nstringData:\n  ONE_AUTH: fixture-secret\n"
    stub_const('ONEKS_CLUSTER_SPEC', Base64.strict_encode64(spec))
    stub_const('ONEKS_CNI_DAEMONSET', 'rke2-canal')
    commands = []
    allow(described_class).to receive(:bash) { |script| commands << script; '' }
    allow(described_class).to receive(:onegate_vm_update)
    allow(described_class).to receive(:qualify_provider_startup)
    allow(described_class).to receive(:begin_retry?).and_yield.and_return(true)
    status = double('status', success?: true)
    expect(Open3).to receive(:capture3).with('kubectl', 'apply', '--kubeconfig',
        ONEKS_MGMT_KUBECONFIG_PATH, '-f', '-', stdin_data: spec).and_return(['', '', status])
    expect(Open3).to receive(:capture3).with('kubectl', '--kubeconfig', ONEKS_WKLD_KUBECONFIG_PATH,
        'rollout', 'status', 'daemonset/rke2-canal', '-n', 'kube-system',
        "--timeout=#{ONEKS_READY_TIMEOUT_SECONDS}s").and_return(['', '', status])
    described_class.configure
    expect(commands.join).not_to include('fixture-secret', Base64.strict_encode64(spec))
    expect(commands.join).to include('--for=condition=ControlPlaneAvailable')
    expect(commands.join).not_to include('--for=condition=ControlPlaneReady')
    expect(commands.join).to include('kubectl wait nodes --all --for=condition=Ready')
  end
end
