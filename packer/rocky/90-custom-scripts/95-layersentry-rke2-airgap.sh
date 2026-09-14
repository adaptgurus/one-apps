#!/usr/bin/env bash
set -euo pipefail

[[ "${LAYERSENTRY_RKE2_AIRGAP:-false}" == "true" ]] || exit 0
[[ "${DIST_VER:-}" == "9" && "${DIST_ARCH:-}" == "x86_64" ]] || {
    echo "LayerSentry RKE2 image requires Rocky 9 x86_64" >&2
    exit 1
}
grep -Eq 'Rocky Linux release 9\.8' /etc/rocky-release || {
    echo "LayerSentry RKE2 image is pinned to Rocky Linux 9.8" >&2
    exit 1
}

RKE2_VERSION='v1.36.4+rke2r1'
INSTALL_SHA='42983c86d1da64a92061d83afb57630cedd69241989f1b0673f3db6c3d92ee6b'
CHECKSUM_SHA='8e12805c4bda79bec2fd20c89f705af3cb2ed11ea8854dc4937fca41b124b57a'
RKE2_SHA='7bcbd3167d6947e1d79cdf722acdc740b28021fefb50dd5b974a1980776d4079'
CORE_SHA='8988a2eff587dd88b8eab86fe719703e9541a1f08d22771a94cbec446a13db86'
CANAL_SHA='4359b651bfdec8f3bcc01b351b33a55ff21f06b18a767366db6f3800d5750871'
RELEASE_URL='https://github.com/rancher/rke2/releases/download/v1.36.4%2Brke2r1'
INSTALL_URL="https://raw.githubusercontent.com/rancher/rke2/${RKE2_VERSION}/install.sh"

tmpdir=$(mktemp -d /var/tmp/layersentry-rke2.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

download_verify() {
    local url=$1 dest=$2 sha=$3
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 --max-time 1800 \
        "$url" -o "$dest"
    printf '%s  %s\n' "$sha" "$dest" | sha256sum -c -
}

dnf -y install \
    ca-certificates curl e2fsprogs policycoreutils-python-utils \
    qemu-guest-agent xfsprogs

install -d -m 0755 /opt/rke2-artifacts
install -d -m 0755 /var/lib/rancher/rke2/agent/images
install -d -m 0755 /usr/local/libexec/oneks

download_verify "$INSTALL_URL" "$tmpdir/install.sh" "$INSTALL_SHA"
download_verify "$RELEASE_URL/sha256sum-amd64.txt" \
    "$tmpdir/sha256sum-amd64.txt" "$CHECKSUM_SHA"
download_verify "$RELEASE_URL/rke2.linux-amd64.tar.gz" \
    "$tmpdir/rke2.linux-amd64.tar.gz" "$RKE2_SHA"
download_verify "$RELEASE_URL/rke2-images-core.linux-amd64.tar.zst" \
    "$tmpdir/rke2-images-core.linux-amd64.tar.zst" "$CORE_SHA"
download_verify "$RELEASE_URL/rke2-images-canal.linux-amd64.tar.zst" \
    "$tmpdir/rke2-images-canal.linux-amd64.tar.zst" "$CANAL_SHA"

grep -Fqx "$RKE2_SHA  rke2.linux-amd64.tar.gz" "$tmpdir/sha256sum-amd64.txt"
install -m 0755 "$tmpdir/install.sh" /opt/install.sh
install -m 0644 "$tmpdir/sha256sum-amd64.txt" /opt/rke2-artifacts/sha256sum-amd64.txt
install -m 0644 "$tmpdir/rke2.linux-amd64.tar.gz" /opt/rke2-artifacts/rke2.linux-amd64.tar.gz
install -m 0644 "$tmpdir/rke2-images-core.linux-amd64.tar.zst" \
    /var/lib/rancher/rke2/agent/images/rke2-images-core.linux-amd64.tar.zst
install -m 0644 "$tmpdir/rke2-images-canal.linux-amd64.tar.zst" \
    /var/lib/rancher/rke2/agent/images/rke2-images-canal.linux-amd64.tar.zst

cat <<'SHA256' | sha256sum -c -
42983c86d1da64a92061d83afb57630cedd69241989f1b0673f3db6c3d92ee6b  /opt/install.sh
8e12805c4bda79bec2fd20c89f705af3cb2ed11ea8854dc4937fca41b124b57a  /opt/rke2-artifacts/sha256sum-amd64.txt
7bcbd3167d6947e1d79cdf722acdc740b28021fefb50dd5b974a1980776d4079  /opt/rke2-artifacts/rke2.linux-amd64.tar.gz
8988a2eff587dd88b8eab86fe719703e9541a1f08d22771a94cbec446a13db86  /var/lib/rancher/rke2/agent/images/rke2-images-core.linux-amd64.tar.zst
4359b651bfdec8f3bcc01b351b33a55ff21f06b18a767366db6f3800d5750871  /var/lib/rancher/rke2/agent/images/rke2-images-canal.linux-amd64.tar.zst
SHA256

cat > /usr/local/libexec/oneks/kubectl <<'EOF_KUBECTL'
#!/bin/sh
exec /var/lib/rancher/rke2/bin/kubectl "$@"
EOF_KUBECTL
chmod 0750 /usr/local/libexec/oneks/kubectl

cat > /usr/local/libexec/oneks/worker-disk <<'EOF_DISK'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

valid_mount() {
    case "${1:-}" in
        /) return 0 ;;
        /var/lib/layersentry/disks/*)
            [[ "$1" =~ ^/var/lib/layersentry/disks/[a-z][a-z0-9-]{0,30}$ ]]
            return
            ;;
        *) return 1 ;;
    esac
}

action=${1:-}
shift || true
case "$action" in
    status)
        [[ $# -ge 1 ]] || exit 64
        for mount in "$@"; do
            valid_mount "$mount" || exit 64
            /usr/bin/mountpoint -q "$mount" || exit 65
        done
        exec /usr/bin/df -Pk "$@"
        ;;
    grow)
        [[ $# -eq 1 ]] || exit 64
        mount=$1
        valid_mount "$mount" || exit 64
        /usr/bin/mountpoint -q "$mount" || exit 65
        fs=$(/usr/bin/findmnt -n -o FSTYPE --target "$mount")
        source=$(/usr/bin/findmnt -n -o SOURCE --target "$mount")
        case "$fs" in
            xfs) exec /usr/sbin/xfs_growfs "$mount" ;;
            ext4) exec /usr/sbin/resize2fs "$source" ;;
            *) exit 66 ;;
        esac
        ;;
    *) exit 64 ;;
esac
EOF_DISK
chmod 0750 /usr/local/libexec/oneks/worker-disk

qga=/etc/sysconfig/qemu-ga
current=$(sed -n 's/^FILTER_RPC_ARGS="--allow-rpcs=\(.*\)"$/\1/p' "$qga")
[[ -n "$current" ]] || {
    echo 'qemu-ga allow-rpcs configuration missing' >&2
    exit 1
}
for rpc in guest-exec guest-exec-status; do
    case ",$current," in
        *,$rpc,*) ;;
        *) current="${current},${rpc}" ;;
    esac
done
sed -i "s|^FILTER_RPC_ARGS=.*|FILTER_RPC_ARGS=\"--allow-rpcs=${current}\"|" "$qga"
systemctl enable qemu-guest-agent

if selinuxenabled; then
    for helper in /usr/local/libexec/oneks/kubectl /usr/local/libexec/oneks/worker-disk; do
        semanage fcontext -a -t virt_qemu_ga_unconfined_exec_t "$helper" 2>/dev/null || \
            semanage fcontext -m -t virt_qemu_ga_unconfined_exec_t "$helper"
        restorecon "$helper"
    done
    setsebool -P virt_qemu_ga_run_unconfined on
fi

printf 'LayerSentry Rocky 9.8 RKE2 %s air-gap artifacts installed and verified.\n' "$RKE2_VERSION"
