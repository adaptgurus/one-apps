#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 OUTPUT_ISO USER_DATA" >&2; exit 64; }
out=$1
user_data=$2

if command -v cloud-localds >/dev/null 2>&1; then
    exec cloud-localds "$out" "$user_data"
fi

if ! command -v genisoimage >/dev/null 2>&1; then
    echo 'cloud-localds or genisoimage is required to build the cloud-init seed ISO' >&2
    exit 69
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
install -m 0644 "$user_data" "$tmpdir/user-data"
printf 'instance-id: packer\nlocal-hostname: packer\n' > "$tmpdir/meta-data"
genisoimage -quiet -output "$out" -volid cidata -joliet -rock \
    "$tmpdir/user-data" "$tmpdir/meta-data"
