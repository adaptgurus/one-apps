#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
build="$repo/packer/rocky/90-custom-scripts/95-layersentry-rke2-airgap.sh"
vars="$repo/packer/rocky/variables.pkr.hcl"
rocky="$repo/packer/rocky/rocky.pkr.hcl"

bash -n "$repo/packer/make-cloud-init-iso.sh"
bash -n "$build"
bash -n "$repo/packer/layersentry-poc/build-rocky-rke2-airgap.sh"

grep -Fq "RKE2_VERSION='v1.36.4+rke2r1'" "$build"
grep -Fq '42983c86d1da64a92061d83afb57630cedd69241989f1b0673f3db6c3d92ee6b' "$build"
grep -Fq '8e12805c4bda79bec2fd20c89f705af3cb2ed11ea8854dc4937fca41b124b57a' "$build"
grep -Fq '7bcbd3167d6947e1d79cdf722acdc740b28021fefb50dd5b974a1980776d4079' "$build"
grep -Fq '8988a2eff587dd88b8eab86fe719703e9541a1f08d22771a94cbec446a13db86' "$build"
grep -Fq '4359b651bfdec8f3bcc01b351b33a55ff21f06b18a767366db6f3800d5750871' "$build"
grep -Fq '/usr/local/libexec/oneks/worker-disk' "$build"
grep -Fq 'virt_qemu_ga_unconfined_exec_t' "$build"
grep -Fq 'qemu-guest-agent' "$build"
grep -Fq 'guest-exec guest-exec-status' "$build"
grep -Fq 'Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2' "$vars"
grep -Fq 'sha256:92c206cc6f790c61583247eefe87890f8828420662c17cacf247cec78ab4eec8' "$vars"
grep -Fq '9-layersentry.x86_64' "$rocky"
grep -Fq 'qemu_binary_override' "$rocky"
grep -Fq 'make-cloud-init-iso.sh' "$rocky"

if grep -Fq 'get.rke2.io' "$build"; then
    echo 'image build must not depend on get.rke2.io' >&2
    exit 1
fi
if grep -Eq '(^|[[:space:]])(eval|sh -c|bash -c)([[:space:]]|$)' "$build"; then
    echo 'worker image helper/build source must not expose shell-eval actions' >&2
    exit 1
fi
printf 'LayerSentry Rocky RKE2 air-gap image source checks passed.\n'
