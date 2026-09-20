#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"

export LAYERSENTRY_RKE2_AIRGAP=true
export PACKER_HEADLESS=${PACKER_HEADLESS:-true}
export DIR_EXPORT=${DIR_EXPORT:-export-layersentry}
export DIR_BUILD=${DIR_BUILD:-build-layersentry}

if [[ -z "${PACKER_QEMU_BINARY_OVERRIDE:-}" ]]; then
    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        export PACKER_QEMU_BINARY_OVERRIDE=$(command -v qemu-system-x86_64)
    elif [[ -x /usr/libexec/qemu-kvm ]]; then
        export PACKER_QEMU_BINARY_OVERRIDE=/usr/libexec/qemu-kvm
    else
        echo 'No usable x86_64 QEMU binary found' >&2
        exit 1
    fi
fi

mkdir -p "$DIR_EXPORT" "$DIR_BUILD"
make context-linux
image="$DIR_EXPORT/layersentry-rocky9.8-rke2-v1.36.4-rke2r1.qcow2"
packer/build.sh rocky 9 "$image"
test -s "$image"
sha256sum "$image" > "$image.sha256"
printf 'Built %s\n' "$image"
printf 'Digest: '
cat "$image.sha256"
