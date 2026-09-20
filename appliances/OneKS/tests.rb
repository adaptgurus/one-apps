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
  it 'pins all three native provider versions during initialization' do
    Dir.mktmpdir do |dir|
      script = nil
      timeout_config = nil
      allow(described_class).to receive(:bash) do |value|
        script = value
        timeout_config = File.read(value.match(/--config (\S+)/)[1])
        ''
      end
      expect(described_class).to receive(:qualify_provider_startup).with('/run/qualification.kubeconfig')
      described_class.initialize_providers('/run/qualification.kubeconfig', overrides_path: dir)
      expect(timeout_config).to include(
        "cert-manager:\n  timeout: #{ONEKS_READY_TIMEOUT_SECONDS}s\n",
        "overridesFolder: #{dir}\n"
      )
      expect(script).to include('--core=cluster-api:v1.13.5', '--bootstrap=rke2:v0.25.2',
                               '--control-plane=rke2:v0.25.2', '--infrastructure=opennebula:v0.1.8')
    end
  end
  it 'passes the specification through stdin without shell interpolation' do
    spec = "apiVersion: v1\nkind: Secret\nstringData:\n  ONE_AUTH: fixture-secret\n"
    stub_const('ONEKS_CLUSTER_SPEC', Base64.strict_encode64(spec))
    stub_const('ONEKS_CNI_DAEMONSET', 'rke2-canal')
    commands = []
    allow(described_class).to receive(:bash) { |script| commands << script; '' }
    allow(described_class).to receive(:onegate_vm_update)
    allow(described_class).to receive(:qualify_provider_startup)
    allow(described_class).to receive(:wait_for_management_api)
      .with(ONEKS_MGMT_KUBECONFIG_PATH).and_return(true)
    allow(described_class).to receive(:prepare_provider_overrides).and_return('/tmp/provider-metadata.yaml')
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

RSpec.describe Service::OneKS, 'management bootstrap' do
  before do
    stub_const('ONEKS_KIND_BOOTSTRAP_TIMEOUT_SECONDS', 600)
  end

  def install_fake_management_commands(directory)
    log = File.join(directory, 'commands.log')
    kind = File.join(directory, 'kind')
    podman = File.join(directory, 'podman')
    File.write(kind, <<~'SH')
      #!/bin/sh
      if [ "$1 $2" = "get clusters" ]; then
        [ "${FAKE_DISCOVERY_FAIL:-0}" = 1 ] && exit 17
        [ "${FAKE_CLUSTER_PRESENT:-0}" = 1 ] && printf '%s\n' kind
        exit 0
      fi
      if [ "$1 $2" = "create cluster" ]; then
        printf '%s\n' create >> "$FAKE_COMMAND_LOG"
        [ "${FAKE_CREATE_FAIL:-0}" = 1 ] && exit 18
        exit 0
      fi
      if [ "$1 $2" = "get kubeconfig" ]; then
        printf '%s\n' export >> "$FAKE_COMMAND_LOG"
        [ "${FAKE_EXPORT_FAIL:-0}" = 1 ] && exit 19
        printf '%s\n' fixture-kubeconfig
        exit 0
      fi
      exit 20
    SH
    File.write(podman, <<~'SH')
      #!/bin/sh
      printf '%s\n' resume >> "$FAKE_COMMAND_LOG"
      [ "${FAKE_RESUME_FAIL:-0}" = 1 ] && exit 21
      exit 0
    SH
    File.chmod(0o700, kind)
    File.chmod(0o700, podman)
    [log, { 'PATH' => "#{directory}:#{ENV.fetch('PATH')}", 'FAKE_COMMAND_LOG' => log }]
  end

  def use_real_management_shell(environment)
    allow(described_class).to receive(:bash) do |script|
      _out, err, status = Open3.capture3(
        environment,
        '/bin/bash', '-c', "set -o errexit -o nounset -o pipefail\n#{script}"
      )
      raise "management shell failed: #{status.exitstatus}: #{err}" unless status.success?
    end
  end

  it 'configures the kubeadm API-call budget before kind starts' do
    config = described_class.management_cluster_config
    expect(config.fetch('apiVersion')).to eq('kind.x-k8s.io/v1alpha4')
    expect(config.fetch('kind')).to eq('Cluster')
    init = YAML.safe_load(config.fetch('kubeadmConfigPatches').fetch(0))
    expect(init.fetch('apiVersion')).to eq('kubeadm.k8s.io/v1beta4')
    expect(init.fetch('kind')).to eq('InitConfiguration')
    expect(init.fetch('timeouts')).to eq(
      'kubernetesAPICall' => '600s',
      'controlPlaneComponentHealthCheck' => '600s'
    )
    expect(config.to_s).not_to include('skipPhases', 'ignorePreflightErrors')
  end

  it 'uses the validated lower and upper bootstrap timeout bounds' do
    [60, 1800].each do |seconds|
      stub_const('ONEKS_KIND_BOOTSTRAP_TIMEOUT_SECONDS', seconds)
      init = YAML.safe_load(
        described_class.management_cluster_config.fetch('kubeadmConfigPatches').fetch(0)
      )
      expect(init.fetch('timeouts').values).to contain_exactly("#{seconds}s", "#{seconds}s")
    end
  end

  it 'passes a private temporary config to the pinned native kind command' do
    paths = []
    allow(described_class).to receive(:bash) do |script|
      path = script.match(/--config (\S+)/)[1]
      paths << path
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(YAML.safe_load(File.read(path))).to eq(described_class.management_cluster_config)
      expect(script).to include(ONEKS_KIND_IMAGE, '--wait 600s')
      expect(script).to include('clusters=$(kind get clusters)')
      ''
    end
    described_class.start_management_cluster
    expect(paths.size).to eq(1)
    expect(paths.none? { |path| File.exist?(path) }).to be(true)
  end

  it 'cleans the private temporary config when the shell raises' do
    path = nil
    allow(described_class).to receive(:bash) do |script|
      path = script.match(/--config (\S+)/)[1]
      expect(File).to exist(path)
      raise 'fixture failure'
    end
    expect { described_class.start_management_cluster }.to raise_error('fixture failure')
    expect(File).not_to exist(path)
  end

  it 'does not create or export when management cluster discovery fails' do
    Dir.mktmpdir do |dir|
      log, environment = install_fake_management_commands(dir)
      environment['FAKE_DISCOVERY_FAIL'] = '1'
      stub_const('ONEKS_MGMT_KUBECONFIG_PATH', File.join(dir, 'mgmt'))
      use_real_management_shell(environment)

      expect { described_class.start_management_cluster }.to raise_error(/management shell failed: 17/)
      expect(File).not_to exist(log)
      expect(File).not_to exist(ONEKS_MGMT_KUBECONFIG_PATH)
    end
  end

  it 'stops after one failed native create attempt without exporting kubeconfig' do
    Dir.mktmpdir do |dir|
      log, environment = install_fake_management_commands(dir)
      environment['FAKE_CREATE_FAIL'] = '1'
      stub_const('ONEKS_MGMT_KUBECONFIG_PATH', File.join(dir, 'mgmt'))
      use_real_management_shell(environment)

      expect { described_class.start_management_cluster }.to raise_error(/management shell failed: 18/)
      expect(File.readlines(log, chomp: true)).to eq(['create'])
      expect(File).not_to exist(ONEKS_MGMT_KUBECONFIG_PATH)
    end
  end

  it 'stops when an existing management container cannot resume' do
    Dir.mktmpdir do |dir|
      log, environment = install_fake_management_commands(dir)
      environment['FAKE_CLUSTER_PRESENT'] = '1'
      environment['FAKE_RESUME_FAIL'] = '1'
      stub_const('ONEKS_MGMT_KUBECONFIG_PATH', File.join(dir, 'mgmt'))
      use_real_management_shell(environment)

      expect { described_class.start_management_cluster }.to raise_error(/management shell failed: 21/)
      expect(File.readlines(log, chomp: true)).to eq(['resume'])
      expect(File).not_to exist(ONEKS_MGMT_KUBECONFIG_PATH)
    end
  end

  it 'propagates kubeconfig export failure after a successful native create' do
    Dir.mktmpdir do |dir|
      log, environment = install_fake_management_commands(dir)
      environment['FAKE_EXPORT_FAIL'] = '1'
      stub_const('ONEKS_MGMT_KUBECONFIG_PATH', File.join(dir, 'mgmt'))
      use_real_management_shell(environment)

      expect { described_class.start_management_cluster }.to raise_error(/management shell failed: 19/)
      expect(File.readlines(log, chomp: true)).to eq(%w[create export])
    end
  end

  it 'classifies a raising shell helper as management startup failure' do
    stub_const('ONEKS_CLUSTER_SPEC', Base64.strict_encode64('fixture'))
    allow(described_class).to receive(:start_onegate_heartbeat)
    expect(described_class).to receive(:stop_onegate_heartbeat)
    allow(described_class).to receive(:report_onegate_state)
    allow(described_class).to receive(:start_management_cluster)
      .and_raise(RuntimeError, 'fixture kind failed')
    expect(described_class).to receive(:report_onegate_state)
      .with('PROVISIONING_FAILURE', 'MGMT_CLUSTER_START_FAILED')
    expect(described_class).not_to receive(:wait_for_management_api)
    expect(described_class).not_to receive(:initialize_providers)
    expect { described_class.configure }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
  end

  it 'does not initialize providers after management startup failure' do
    stub_const('ONEKS_CLUSTER_SPEC', Base64.strict_encode64('fixture'))
    allow(described_class).to receive(:start_onegate_heartbeat)
    allow(described_class).to receive(:stop_onegate_heartbeat)
    allow(described_class).to receive(:report_onegate_state)
    allow(described_class).to receive(:start_management_cluster).and_raise('fixture failure')
    expect(described_class).not_to receive(:wait_for_management_api)
    expect(described_class).not_to receive(:initialize_providers)

    expect { described_class.configure }.to raise_error(SystemExit)
  end

  it 'rejects invalid bootstrap budgets before executing commands' do
    %w[0 59 1801 garbage].each do |value|
      _out, err, status = Open3.capture3({'ONEAPP_ONEKS_KIND_BOOTSTRAP_TIMEOUT_SECONDS' => value},
        RbConfig.ruby, '-r', File.expand_path('main', __dir__), '-e', 'exit 0')
      expect(status.success?).to be(false), value
      expect(err).not_to be_empty
    end
  end
end
