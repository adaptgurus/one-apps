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

        def initialize_providers(kubeconfig)
            Tempfile.create(['oneks-clusterctl-', '.yaml']) do |config|
                config.write("cert-manager:\n  timeout: #{ONEKS_READY_TIMEOUT_SECONDS}s\n")
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

            begin
                if ONEKS_CLUSTER_SPEC.nil? || ONEKS_CLUSTER_SPEC.strip.empty?
                    msg :error, 'ONEKS_CLUSTER_SPEC is empty or not provided'
                    onegate_vm_update ["#{ONEKS_STATE_KEY}=BOOTSTRAP_FAILURE"]
                    exit 1
                end

                msg :info, 'Start Management Cluster'
                onegate_vm_update ["#{ONEKS_STATE_KEY}=PROVISIONING_MGMT"]
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
                    onegate_vm_update ["#{ONEKS_STATE_KEY}=PROVISIONING_FAILURE"]
                    exit 1
                end

                initialize_providers(ONEKS_MGMT_KUBECONFIG_PATH)

                msg :info, 'Deploy Workload Cluster'
                onegate_vm_update ["#{ONEKS_STATE_KEY}=PROVISIONING_CP"]
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
                    onegate_vm_update ["#{ONEKS_STATE_KEY}=PROVISIONING_FAILURE"]
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
                    onegate_vm_update ["#{ONEKS_STATE_KEY}=PROVISIONING_FAILURE"]
                    exit 1
                end
            rescue StandardError => e
                msg :error, "Unexpected error: #{e.message}"
                onegate_vm_update ["#{ONEKS_STATE_KEY}=PROVISIONING_FAILURE"]
                exit 1
            end

            begin
                onegate_vm_update ["#{ONEKS_STATE_KEY}=PIVOTING_CLUSTER"]
                msg :info, 'Retrieve Workload Cluster Kubeconfig'
                unless bash <<~SCRIPT
                    umask 077
                    clusterctl get kubeconfig #{ONEKS_CLUSTER_NAME} \
                    --kubeconfig #{ONEKS_MGMT_KUBECONFIG_PATH} > #{ONEKS_WKLD_KUBECONFIG_PATH}
                SCRIPT
                    msg :error, 'Failed to retrieve Workload Cluster Kubeconfig'
                    onegate_vm_update ["#{ONEKS_STATE_KEY}=PIVOTING_FAILURE"]
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
                    onegate_vm_update ["#{ONEKS_STATE_KEY}=PIVOTING_FAILURE"]
                    exit 1
                end
                onegate_vm_update ["#{ONEKS_STATE_KEY}=RUNNING"]
            rescue StandardError => e
                msg :error, "Unexpected error: #{e.message}"
                onegate_vm_update ["#{ONEKS_STATE_KEY}=PIVOTING_FAILURE"]
                exit 1
            end
        end

        def bootstrap
            msg :info, 'Capi::bootstrap'
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
        bash "onegate vm update --data \"#{data.join('\n')}\""
    end

end
