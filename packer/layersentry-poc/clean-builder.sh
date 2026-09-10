#!/usr/bin/env bash
# Run only in a verified task-owned Alpine image builder, immediately before
# OpenNebula poweroff + disk-saveas. Never run on an infrastructure host.
set -euo pipefail
[[ $(id -u) == 0 && -f /etc/alpine-release ]]
[[ -f /usr/share/layersentry/vrouter-packages.txt || -f /usr/share/layersentry/seed-packages.txt ]]
[[ ${1:-} == task-owned-opennebula-builder ]] || exit 1
if command -v podman >/dev/null; then
    [[ -z $(podman ps -aq) ]] || { echo 'Containers remain; remove the qualification cluster first' >&2; exit 1; }
fi
# No reusable login credential or machine identity may enter the image.
rm -f /root/.ssh/authorized_keys /root/.ssh/known_hosts /root/.ash_history /root/.bash_history
rm -f /etc/ssh/ssh_host_* /etc/machine-id /var/lib/dbus/machine-id
rm -rf /root/.kube /root/.config/cluster-api /var/lib/one-context/tmp
rm -f /etc/one-appliance/service.d/OneKS/mgmt /etc/one-appliance/service.d/OneKS/wkld
# Replace any build-time password with an unknown random password hash. SSH
# remains key-only; one-context supplies each instance's authorized public key.
ruby -rdigest -e 'p="/etc/shadow"; secret=Random.urandom(64).unpack1("H*"); salt="$6$"+Random.urandom(8).unpack1("H*"); hash=secret.crypt(salt); s=File.read(p); s.sub!(/^root:[^:]*:/,"root:#{hash}:"); File.write(p,s)'
printf 'localhost\n' > /etc/hostname
printf 'auto lo\niface lo inet loopback\n' > /etc/network/interfaces
: > /etc/resolv.conf
find /var/log -type f -exec truncate -s 0 {} +
find /tmp /var/tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} +
sync
printf 'Builder identity cleaned; power off through OpenNebula now.\n'
