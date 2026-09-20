# frozen_string_literal: true

require 'tempfile'
require 'yaml'

# Base module for OpenNebula services
module Service

    # OneKS management-cluster bootstrap helpers
    module OneKS

        def management_cluster_config
            timeout = "#{ONEKS_KIND_BOOTSTRAP_TIMEOUT_SECONDS}s"

            {
                'apiVersion' => 'kind.x-k8s.io/v1alpha4',
                'kind' => 'Cluster',
                'kubeadmConfigPatches' => [
                    YAML.dump(
                        'apiVersion' => 'kubeadm.k8s.io/v1beta4',
                        'kind' => 'InitConfiguration',
                        'timeouts' => {
                            'kubernetesAPICall' => timeout,
                            'controlPlaneComponentHealthCheck' => timeout
                        }
                    )
                ]
            }
        end

        def start_management_cluster
            Tempfile.create(['oneks-kind-', '.yaml'], '/tmp') do |config|
                File.chmod(0o600, config.path)
                config.write(YAML.dump(management_cluster_config))
                config.flush

                bash <<~SCRIPT
                    umask 077
                    export KIND_EXPERIMENTAL_PROVIDER=podman
                    clusters=$(kind get clusters)
                    if ! printf '%s\n' "$clusters" | grep -qx kind; then
                        kind create cluster \
                            --image #{ONEKS_KIND_IMAGE} \
                            --config #{config.path} \
                            --wait #{ONEKS_KIND_BOOTSTRAP_TIMEOUT_SECONDS}s
                    else
                        podman start kind-control-plane
                    fi
                    kind get kubeconfig > #{ONEKS_MGMT_KUBECONFIG_PATH}
                SCRIPT
            end
        end

    end

end
