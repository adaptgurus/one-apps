#!/usr/bin/env bash
# Run inside a task-owned OpenNebula Alpine builder. Never on the frontend/hosts.
set -euo pipefail
test "$(id -u)" = 0
case "$(cat /etc/alpine-release)" in 3.24.*) ;; *) exit 1 ;; esac
src=$(cd "$(dirname "$0")/../.." && pwd)
test ! -e /etc/one-appliance/service.d/OneKS
apk add bash curl ruby podman iptables ip6tables
rc-update add cgroups boot
rc-service cgroups start
rc-update add podman boot
rc-service podman start
install -d -m 0750 /etc/one-appliance/service.d /etc/one-appliance/lib
install -d -m 0755 /opt/one-appliance/bin
install -m 0755 "$src/appliances/service.rb" /etc/one-appliance/service
install -m 0644 "$src/appliances/lib/helpers.rb" /etc/one-appliance/lib/helpers.rb
cp -a "$src/appliances/OneKS" /etc/one-appliance/service.d/
install -m 0755 "$src/appliances/scripts/net-90-service-appliance" "$src/appliances/scripts/net-99-report-ready" /etc/one-appliance/
bash "$src/packer/service_OneKS/82-configure-context.sh"
/etc/one-appliance/service install
install -d /usr/share/layersentry
apk info -v | sort > /usr/share/layersentry/seed-packages.txt
sha256sum /usr/local/bin/clusterctl /usr/local/bin/kind /usr/local/bin/kubectl > /usr/share/layersentry/seed-binaries.sha256
test -z "$(podman ps -aq)"
test ! -s /etc/one-appliance/service.d/OneKS/mgmt
test ! -s /etc/one-appliance/service.d/OneKS/wkld
sync
