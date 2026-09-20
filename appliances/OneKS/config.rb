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

load_env

ONEKS_CLUSTERCTL_VERSION = env :ONEAPP_ONEKS_CLUSTERCTL_VERSION, '1.13.5'
ONEKS_KIND_VERSION       = env :ONEAPP_ONEKS_KIND_VERSION, '0.32.0'
ONEKS_KUBECTL_VERSION    = env :ONEAPP_ONEKS_KUBECTL_VERSION, '1.36.4'
ONEKS_HELM_VERSION       = env :ONEAPP_ONEKS_HELM_VERSION, '3.17.3'
ONEKS_CAPONE_VERSION     = env :ONEAPP_ONEKS_CAPONE_VERSION, '0.1.8'

ONEKS_CLUSTER_NAME = env :ONEAPP_ONEKS_CLUSTER_NAME, ''
ONEKS_CLUSTER_SPEC = env :ONEAPP_ONEKS_CLUSTER_SPEC, ''
ONEKS_CNI_DAEMONSET = env :ONEAPP_ONEKS_CNI_DAEMONSET, ''
ONEKS_LEADER_ELECTION_GRACE = env(:ONEAPP_ONEKS_LEADER_ELECTION_GRACE, 'NO')
raise 'Invalid OneKS CNI DaemonSet name' unless ONEKS_CNI_DAEMONSET.empty? || ONEKS_CNI_DAEMONSET.match?(/\A[a-z0-9][a-z0-9.-]*\z/)
ONEKS_READY_TIMEOUT_SECONDS = Integer(env(:ONEAPP_ONEKS_READY_TIMEOUT_SECONDS, '900'), 10)
raise 'OneKS readiness timeout must be 60..7200 seconds' unless (60..7200).cover?(ONEKS_READY_TIMEOUT_SECONDS)
ONEKS_MGMT_API_TIMEOUT_SECONDS = Integer(env(:ONEAPP_ONEKS_MGMT_API_TIMEOUT_SECONDS, '600'), 10)
raise 'OneKS management API timeout must be 60..7200 seconds' unless (60..7200).cover?(ONEKS_MGMT_API_TIMEOUT_SECONDS)
ONEKS_KIND_BOOTSTRAP_TIMEOUT_SECONDS = Integer(
    env(:ONEAPP_ONEKS_KIND_BOOTSTRAP_TIMEOUT_SECONDS, '600'), 10
)
raise 'OneKS Kind bootstrap timeout must be 60..1800 seconds' unless
    (60..1800).cover?(ONEKS_KIND_BOOTSTRAP_TIMEOUT_SECONDS)
ONEKS_MGMT_API_INTERVAL_SECONDS = Integer(env(:ONEAPP_ONEKS_MGMT_API_INTERVAL_SECONDS, '5'), 10)
raise 'OneKS management API interval must be 1..60 seconds' unless (1..60).cover?(ONEKS_MGMT_API_INTERVAL_SECONDS)
ONEKS_HEARTBEAT_INTERVAL_SECONDS = Integer(env(:ONEAPP_ONEKS_HEARTBEAT_INTERVAL_SECONDS, '30'), 10)
raise 'OneKS heartbeat interval must be 10..300 seconds' unless (10..300).cover?(ONEKS_HEARTBEAT_INTERVAL_SECONDS)

ONEKS_APPLIANCE_PATH = '/etc/one-appliance/service.d/OneKS'
ONEKS_PROVIDER_OVERRIDES_PATH = env(
    :ONEAPP_ONEKS_PROVIDER_OVERRIDES_PATH,
    "#{ONEKS_APPLIANCE_PATH}/cluster-api-overrides"
)
ONEKS_MGMT_KUBECONFIG_PATH = "#{ONEKS_APPLIANCE_PATH}/mgmt"
ONEKS_WKLD_KUBECONFIG_PATH = "#{ONEKS_APPLIANCE_PATH}/wkld"
ONEKS_STATE_KEY = 'ONEKS_STATE'
ONEKS_HEARTBEAT_AT_KEY = 'ONEKS_HEARTBEAT_AT'
ONEKS_HEARTBEAT_SEQ_KEY = 'ONEKS_HEARTBEAT_SEQ'
ONEKS_ERROR_CODE_KEY = 'ONEKS_ERROR_CODE'

ONEKS_CAPRKE2_VERSION = env :ONEAPP_ONEKS_CAPRKE2_VERSION, '0.25.2'
ONEKS_CAPI_CONTRACT     = 'v1beta2'
ONEKS_CAPRKE2_CONTRACT  = 'v1beta2'
ONEKS_CAPONE_CONTRACT   = 'v1beta1'
ONEKS_KIND_IMAGE = 'docker.io/kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5'
# Version overrides require corresponding reviewed release digests.
ONEKS_BINARY_DIGESTS = {
    'clusterctl' => ['1.13.5', {
        'amd64' => '975e697ba4cb62f148e3709b6b102ed2c045d6c77f1fd20fd0d8cd328a22a0b9',
        'arm64' => 'a731355594d664d3409eeb9dad868c7edcfd8b2cd0b971b9e0ff133e379f0fcb'}],
    'kind' => ['0.32.0', {
        'amd64' => '50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54',
        'arm64' => 'b92cd615e97585de8ddade28ed5cd7feb4248d717c233eea5b03c37298900f5d'}],
    'kubectl' => ['1.36.4', {
        'amd64' => '8b8f088da2dab964f853b38464033b1be15ede2839eca751482357c45abdd05a',
        'arm64' => '0ecf44450ee6063bf19dd166a103ee6df4a9034455c2abce626e6eea657d73fb'}]
}.freeze
