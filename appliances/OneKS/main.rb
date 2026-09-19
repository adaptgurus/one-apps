# frozen_string_literal: true

# ---------------------------------------------------------------------------- #
# Copyright 2025, OpenNebula Project, OpenNebula Systems                       #
#                                                                              #
# Licensed under the Apache License, Version 2.0 (the "License"); you may      #
# not use this file except in compliance with the License. You may obtain      #
# a copy of the License at                                                     #
#                                                                              #
# http://www.apache.org/licenses/LICENSE-2.0                                   #
#                                                                              #
# Unless required by applicable law or agreed to in writing, software          #
# distributed under the License is distributed on an "AS IS" BASIS,            #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     #
# See the License for the specific language governing permissions and          #
# limitations under the License.                                               #
# ---------------------------------------------------------------------------- #

begin
    require '/etc/one-appliance/lib/helpers'
rescue LoadError
    require_relative '../lib/helpers'
end

require_relative 'config'
require 'base64'
require 'open3'
require 'rbconfig'
require 'tempfile'
require 'fileutils'
require 'yaml'

# Base module for OpenNebula services
module Service

    # OneKS Appliance
    module OneKS

        extend self

        DEPENDS_ON = []

        def install
            msg :info, 'OneKS::install'

            arch = RbConfig::CONFIG['host_cpu'] =~ /arm64|aarch64/ ? 'arm64' : 'amd64'
            binaries = {
                'clusterctl' => [ONEKS_CLUSTERCTL_VERSION, 'https://github.com/kubernetes-sigs/cluster-api/releases/download'],
                'kind' => [ONEKS_KIND_VERSION, 'https://github.com/kubernetes-sigs/kind/releases/download'],
                'kubectl' => [ONEKS_KUBECTL_VERSION, 'https://dl.k8s.io/release']
            }
            binaries.each do |name, (version, base)|
                approved_version, digests = ONEKS_BINARY_DIGESTS.fetch(name)
                raise "Unqualified #{name} version" unless version == approved_version
                digest = digests.fetch(arch)
                suffix = name == 'kubectl' ? "bin/linux/#{arch}/kubectl" : "#{name}-linux-#{arch}"
                bash <<~SCRIPT
                    curl -fsSL '#{base}/v#{version}/#{suffix}' -o /tmp/oneks-#{name}
                    echo '#{digest}  /tmp/oneks-#{name}' | sha256sum -c -
                    install -m 0700 /tmp/oneks-#{name} /usr/local/bin/#{name}
                    rm /tmp/oneks-#{name}
                SCRIPT
            end
            # Cache only the immutable node image. Each seed creates fresh cluster credentials.
            bash "podman pull #{ONEKS_KIND_IMAGE}"
        end

        def validate_provider_metadata!(metadata, provider_label)
            expected_api = 'clusterctl.cluster.x-k8s.io/v1alpha3'
            raise "#{provider_label} metadata apiVersion must be #{expected_api}" unless metadata['apiVersion'] == expected_api
            raise "#{provider_label} metadata kind must be Metadata" unless metadata['kind'] == 'Metadata'

            series = metadata['releaseSeries']
            raise "#{provider_label} metadata releaseSeries must not be empty" unless series.is_a?(Array) && !series.empty?

            true
        end

        def prepare_provider_overrides(overrides_path = ONEKS_PROVIDER_OVERRIDES_PATH)
            raise "Unqualified CAPONE metadata override version #{ONEKS_CAPONE_VERSION}" unless ONEKS_CAPONE_VERSION == '0.1.8'
            raise 'Provider overrides path must be absolute' unless overrides_path.to_s.start_with?('/')

            metadata = {
                'apiVersion' => 'clusterctl.cluster.x-k8s.io/v1alpha3',
                'kind' => 'Metadata',
                'releaseSeries' => [
                    {'major' => 0, 'minor' => 1, 'contract' => 'v1beta1'}
                ]
            }
            validate_provider_metadata!(metadata, "opennebula:v#{ONEKS_CAPONE_VERSION}")

            directory = File.join(
                overrides_path,
                'infrastructure-opennebula',
                "v#{ONEKS_CAPONE_VERSION}"
            )
            FileUtils.mkdir_p(directory, :mode => 0o700)
            File.chmod(0o700, directory)
            path = File.join(directory, 'metadata.yaml')
            File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
                file.write(YAML.dump(metadata))
            end
            File.chmod(0o600, path)
            path
        end

        def initialize_providers(kubeconfig, overrides_path: ONEKS_PROVIDER_OVERRIDES_PATH)
            prepare_provider_overrides(overrides_path)
            Tempfile.create(['oneks-clusterctl-', '.yaml']) do |config|
                config.write("cert-manager:\n  timeout: #{ONEKS_READY_TIMEOUT_SECONDS}s\n")
                config.write("overridesFolder: #{overrides_path}\n")
                config.flush
                bash <<~SCRIPT
                    clusterctl init \
                    --config #{config.path} \
                    --core=cluster-api:v#{ONEKS_CLUSTERCTL_VERSION} \
                    --bootstrap=rke2:v#{ONEKS_CAPRKE2_VERSION} \
                    --control-plane=rke2:v#{ONEKS_CAPRKE2_VERSION} \
                    --infrastructure=opennebula:v#{ONEKS_CAPONE_VERSION} \
                    --kubeconfig #{kubeconfig}
                SCRIPT
            end
            qualify_provider_startup(kubeconfig)
        end

        # Nested POC CPUs need startup grace before liveness checks can restart a provider.
        def qualify_provider_startup(kubeconfig)
            namespaces = %w[capi-system capone-system rke2-bootstrap-system rke2-control-plane-system]
            out, _err, status = Open3.capture3('kubectl', '--kubeconfig', kubeconfig,
                                               'get', 'deployments', '-A', '-o', 'json')
            raise 'Unable to inspect native provider deployments' unless status.success?
            deployments = JSON.parse(out).fetch('items').select do |deployment|
                namespaces.include?(deployment.dig('metadata', 'namespace'))
            end
            raise 'Native provider deployment set is incomplete' unless deployments.size == 4
            deployments.each do |deployment|
                containers = deployment.dig('spec', 'template', 'spec', 'containers').filter_map do |container|
                    probe = container['livenessProbe']
                    next unless probe
                    tuned = {'name' => container['name'],
                     'startupProbe' => probe.merge('failureThreshold' => 60, 'timeoutSeconds' => 5,
                                                   'periodSeconds' => 10),
                     'livenessProbe' => probe.merge('timeoutSeconds' => 5)}
                    if ONEKS_LEADER_ELECTION_GRACE
                        # Measured probe timeouts killed healthy managers during cache startup.
                        tuned['startupProbe']['timeoutSeconds'] = 15
                        tuned['livenessProbe'] = probe.merge('timeoutSeconds' => 15,
                            'periodSeconds' => 20, 'failureThreshold' => 6)
                        if container['readinessProbe']
                            tuned['readinessProbe'] = container['readinessProbe'].merge(
                                'timeoutSeconds' => 15, 'periodSeconds' => 20)
                        end
                    end
                    if ONEKS_LEADER_ELECTION_GRACE && deployment.dig('metadata', 'namespace') != 'capone-system'
                        # These flags are supported by the pinned CAPI/CAPRKE2 binaries.
                        # Keep leader election enabled; tolerate measured nested API latency.
                        flags = {'--leader-elect-lease-duration' => '60s',
                                 '--leader-elect-renew-deadline' => '40s',
                                 '--leader-elect-retry-period' => '10s'}
                        args = Array(container['args'])
                        raise 'Use key=value leader election options' unless (args & flags.keys).empty?
                        tuned['args'] = args.reject do |arg|
                            flags.keys.any? {|key| arg.start_with?("#{key}=") }
                        end + flags.map {|key, value| "#{key}=#{value}" }
                    end
                    tuned
                end
                patch = {'spec' => {'template' => {'spec' => {'containers' => containers}}}}
                _out, _err, status = Open3.capture3('kubectl', '--kubeconfig', kubeconfig,
                    'patch', 'deployment', deployment.dig('metadata', 'name'),
                    '-n', deployment.dig('metadata', 'namespace'), '--type=strategic',
                    '--patch-file=/dev/stdin', :stdin_data => JSON.generate(patch))
                raise 'Unable to configure native provider startup grace' unless status.success?
            end
            deployments.each do |deployment|
                _out, _err, status = Open3.capture3('kubectl', '--kubeconfig', kubeconfig,
                    'rollout', 'status', "deployment/#{deployment.dig('metadata', 'name')}",
                    '-n', deployment.dig('metadata', 'namespace'), "--timeout=#{ONEKS_READY_TIMEOUT_SECONDS}s")
                raise 'Native provider did not become available' unless status.success?
            end
        end

        def configure
            msg :info, 'OneKS::configure'
            start_onegate_heartbeat

            begin
                begin
                    if ONEKS_CLUSTER_SPEC.nil? || ONEKS_CLUSTER_SPEC.strip.empty?
                        msg :error, 'ONEKS_CLUSTER_SPEC is empty or not provided'
                        report_onegate_state('BOOTSTRAP_FAILURE', 'EMPTY_CLUSTER_SPEC')
                        exit 1
                    end

                    msg :info, 'Start Management Cluster'
                    report_onegate_state('PROVISIONING_MGMT')
                    unless bash <<~SCRIPT
                        umask 077
                        if ! kind get clusters | grep -qx kind; then
                            kind create cluster --image #{ONEKS_KIND_IMAGE} --wait 600s
                        else
                            podman start kind-control-plane
                        fi
                        kind get kubeconfig > #{ONEKS_MGMT_KUBECONFIG_PATH}
                    SCRIPT
                        msg :error, 'Failed to start Management Cluster'
                        report_onegate_state('PROVISIONING_FAILURE', 'MGMT_CLUSTER_START_FAILED')
                        exit 1
                    end

                    initialize_providers(ONEKS_MGMT_KUBECONFIG_PATH)

                    msg :info, 'Deploy Workload Cluster'
                    report_onegate_state('PROVISIONING_CP')
                    success = begin_retry?(30, 10) do
                        # The specification contains ONE_AUTH. Never interpolate it into a traced shell.
                        _out, _err, status = Open3.capture3(
                            'kubectl', 'apply', '--kubeconfig', ONEKS_MGMT_KUBECONFIG_PATH, '-f', '-',
                            :stdin_data => Base64.strict_decode64(ONEKS_CLUSTER_SPEC)
                        )
                        raise 'kubectl apply failed; specification and diagnostics withheld' unless status.success?
                    end

                    unless success
                        msg :error, 'Failed to deploy Workload Cluster'
                        report_onegate_state('PROVISIONING_FAILURE', 'WORKLOAD_APPLY_FAILED')
                        exit 1
                    end

                    msg :info, 'Wait for Workload Cluster to be ready'
                    unless bash <<~SCRIPT
                        kubectl wait \
                            --for=condition=ControlPlaneAvailable \
                            cluster/#{ONEKS_CLUSTER_NAME} \
                            --timeout="$(( \
                            $(kubectl get RKE2ControlPlane #{ONEKS_CLUSTER_NAME} \
                                -o jsonpath='{.spec.replicas}' \
                                --kubeconfig #{ONEKS_MGMT_KUBECONFIG_PATH}) * #{ONEKS_READY_TIMEOUT_SECONDS} \
                            ))s" \
                            --kubeconfig #{ONEKS_MGMT_KUBECONFIG_PATH}
                    SCRIPT
                        msg :error, 'Workload Cluster is not ready'
                        report_onegate_state('PROVISIONING_FAILURE', 'CONTROL_PLANE_TIMEOUT')
                        exit 1
                    end
                rescue StandardError => e
                    msg :error, "Unexpected error: #{e.message}"
                    report_onegate_state('PROVISIONING_FAILURE', 'PROVISIONING_EXCEPTION')
                    exit 1
                end

                begin
                    report_onegate_state('PIVOTING_CLUSTER')
                    msg :info, 'Retrieve Workload Cluster Kubeconfig'
                    unless bash <<~SCRIPT
                        umask 077
                        clusterctl get kubeconfig #{ONEKS_CLUSTER_NAME} \
                        --kubeconfig #{ONEKS_MGMT_KUBECONFIG_PATH} > #{ONEKS_WKLD_KUBECONFIG_PATH}
                    SCRIPT
                        msg :error, 'Failed to retrieve Workload Cluster Kubeconfig'
                        report_onegate_state('PIVOTING_FAILURE', 'KUBECONFIG_RETRIEVAL_FAILED')
                        exit 1
                    end

                    # API availability precedes CNI readiness. Provider webhooks need pod networking.
                    msg :info, 'Wait for workload node networking before installing providers'
                    bash <<~SCRIPT
                        kubectl wait nodes --all --for=condition=Ready \
                            --timeout=#{ONEKS_READY_TIMEOUT_SECONDS}s \
                            --kubeconfig #{ONEKS_WKLD_KUBECONFIG_PATH}
                    SCRIPT

                    unless ONEKS_CNI_DAEMONSET.empty?
                        _out, _err, status = Open3.capture3(
                            'kubectl', '--kubeconfig', ONEKS_WKLD_KUBECONFIG_PATH,
                            'rollout', 'status', "daemonset/#{ONEKS_CNI_DAEMONSET}",
                            '-n', 'kube-system', "--timeout=#{ONEKS_READY_TIMEOUT_SECONDS}s"
                        )
                        raise 'Workload CNI did not become available' unless status.success?
                    end

                    msg :info, 'Initialize CAPI on Workload Cluster'
                    initialize_providers(ONEKS_WKLD_KUBECONFIG_PATH)

                    msg :info, 'Move CAPI objects to Workload Cluster'
                    success = begin_retry?(30, 10) do
                        puts bash <<~SCRIPT
                            clusterctl -v=4 move \
                            --kubeconfig #{ONEKS_MGMT_KUBECONFIG_PATH} \
                            --to-kubeconfig #{ONEKS_WKLD_KUBECONFIG_PATH}
                        SCRIPT
                    end

                    unless success
                        msg :error, 'Failed to move CAPI objects to Workload Cluster'
                        report_onegate_state('PIVOTING_FAILURE', 'CAPI_MOVE_FAILED')
                        exit 1
                    end
                    report_onegate_state('RUNNING')
                rescue StandardError => e
                    msg :error, "Unexpected error: #{e.message}"
                    report_onegate_state('PIVOTING_FAILURE', 'PIVOT_EXCEPTION')
                    exit 1
                end
            ensure
                stop_onegate_heartbeat
            end
        end

        def bootstrap
            msg :info, 'Capi::bootstrap'
        end

        # Phase transitions and periodic heartbeats use the VM's scoped OneGate
        # context token. No Kubernetes/bootstrap secrets are reported.
        def report_onegate_state(state, error_code = 'NONE')
            @heartbeat_mutex ||= Mutex.new
            @onegate_emit_mutex ||= Mutex.new
            @heartbeat_mutex.synchronize do
                @oneks_state = state
                @oneks_error_code = error_code
            end
            emit_onegate_heartbeat
        end

        def start_onegate_heartbeat
            @heartbeat_mutex = Mutex.new
            @onegate_emit_mutex = Mutex.new
            @heartbeat_cv = ConditionVariable.new
            @heartbeat_seq = 0
            @heartbeat_stop = false
            @oneks_state = 'BOOTSTRAP_STARTING'
            @oneks_error_code = 'NONE'
            emit_onegate_heartbeat

            @heartbeat_thread = Thread.new do
                loop do
                    should_stop = @heartbeat_mutex.synchronize do
                        @heartbeat_cv.wait(@heartbeat_mutex, ONEKS_HEARTBEAT_INTERVAL_SECONDS)
                        @heartbeat_stop
                    end
                    break if should_stop
                    emit_onegate_heartbeat
                end
            rescue StandardError => e
                warn "OneKS heartbeat thread failed: #{e.class}: #{e.message}"
            end
        end

        def stop_onegate_heartbeat
            return unless @heartbeat_thread

            @heartbeat_mutex.synchronize do
                @heartbeat_stop = true
                @heartbeat_cv.broadcast
            end
            @heartbeat_thread.join(5)
            @heartbeat_thread.kill if @heartbeat_thread.alive?
            @heartbeat_thread = nil
        end

        def emit_onegate_heartbeat
            data = @heartbeat_mutex.synchronize do
                @heartbeat_seq += 1
                [
                    "#{ONEKS_STATE_KEY}=#{@oneks_state}",
                    "#{ONEKS_HEARTBEAT_AT_KEY}=#{Time.now.to_i}",
                    "#{ONEKS_HEARTBEAT_SEQ_KEY}=#{@heartbeat_seq}",
                    "#{ONEKS_ERROR_CODE_KEY}=#{@oneks_error_code || 'NONE'}"
                ]
            end
            @onegate_emit_mutex.synchronize { onegate_vm_update(data) }
        end

    end

    def begin_retry?(max_retries, delay)
        max_retries.downto(0).each do |_retry_num|
            yield
            return true
        rescue StandardError => e
            puts "Error: #{e.message}"
            sleep delay
        end
        return false
    end

    def onegate_vm_update(data)
        _out, err, status = Open3.capture3(
            'onegate', 'vm', 'update', '--data', data.join("\n")
        )
        unless status.success?
            warn "OneGate VM update failed: #{err.to_s.lines.first.to_s.strip}"
        end
        status.success?
    rescue StandardError => e
        warn "OneGate VM update failed: #{e.class}: #{e.message}"
        false
    end

end
