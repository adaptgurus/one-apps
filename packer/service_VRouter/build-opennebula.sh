#!/usr/bin/env bash
# Run as root inside an identified disposable OpenNebula Alpine builder.
# VM creation, shutdown and disk-saveas remain owned by OpenNebula.
set -euo pipefail
test "$(id -u)" = 0
case "$(cat /etc/alpine-release)" in 3.24.*) ;; *) echo 'Alpine 3.24 required' >&2; exit 1;; esac
src=$(cd "$(dirname "$0")/../.." && pwd)
test -d "$src/appliances/VRouter"
test ! -e /etc/one-appliance/service.d/VRouter
bash "$src/packer/service_VRouter/10-update.sh"
install -d -m 0750 /etc/one-appliance/service.d /etc/one-appliance/lib
install -d -m 0755 /opt/one-appliance/bin
install -m 0755 "$src/appliances/service.rb" /etc/one-appliance/service
install -m 0644 "$src/appliances/lib/helpers.rb" /etc/one-appliance/lib/helpers.rb
cp -a "$src/appliances/VRouter" /etc/one-appliance/service.d/
install -m 0755 "$src/appliances/scripts/net-90-service-appliance" /etc/one-appliance/
install -m 0755 "$src/appliances/scripts/net-99-report-ready" /etc/one-appliance/
bash "$src/packer/service_VRouter/82-configure-context.sh"
/etc/one-appliance/service install
install -d -m 0755 /usr/share/layersentry
apk info -v | sort > /usr/share/layersentry/vrouter-packages.txt
sha256sum /etc/one-appliance/service /etc/one-appliance/lib/helpers.rb > /usr/share/layersentry/vrouter-source.sha256
sync
