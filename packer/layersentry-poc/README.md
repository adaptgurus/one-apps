# Native OneKS P1 image qualification

These recipes run inside disposable **OpenNebula-owned Alpine 3.24** builder VMs,
never on the frontend, compute hosts or WSL. Provision builders with `onevm create`,
using an approved Marketplace base and existing networking. The seed requires
6 vCPUs, 8 GiB RAM and a 20 GiB disk for runtime qualification in the nested POC; the router builder needs
1 vCPU, 2 GiB RAM and a 4 GiB disk. Final routers use 1 vCPU each.

Run `packer/service_VRouter/build-opennebula.sh` or
`packer/service_OneKS/build-opennebula.sh` as guest root from the source checkout.
Run the appliance tests before cleanup. The seed caches the digest-pinned Kind
node image; it creates new management-cluster credentials during contextualization,
then uses native clusterctl initialization and pivot. A qualification Kind cluster
must be deleted before exporting the seed. Never export its kubeconfig or container.

After saving test evidence, run `clean-builder.sh task-owned-opennebula-builder`
inside the identified builder, then use OpenNebula `onevm poweroff` and
`onevm disk-saveas`. Observe the new image until READY, record its SHA-256, and
only then terminate the task-owned builder. No libvirt-created VM is involved.

The P1 tuple is RKE2 v1.36.4+rke2r1, CAPI 1.13.5, CAPRKE2 0.25.2 and CAPONE 0.1.8.
The seed installer verifies published binary digests. Four provider deployments
receive startup grace for nested CPUs; liveness and TLS verification remain enabled.
Only x86_64 has live POC evidence. ARM64 binary hashes preserve build support but
are not qualification evidence.

The VRouter retains native HAProxy, Keepalived, OneGate and OpenNebula lifecycle.
OneKS/CAPONE supplies two replicas and listeners 6443/9345 through the P1 profile.
An image build or provider admission test is not proof of an RKE2 workload cluster.

References: [OneKS](https://docs.opennebula.io/7.4/platform_services/oneks/getting_started/basic_configuration/),
[profile customization](https://docs.opennebula.io/7.4/platform_services/oneks/management/customizing_specs/).

## LayerSentry Rocky 9.8 RKE2 air-gap node image

`build-rocky-rke2-airgap.sh` extends the existing Rocky Packer path. It does not
mutate an OpenNebula production image in place. The build is pinned to Rocky
9.8 and RKE2 `v1.36.4+rke2r1`; normal Rocky builds remain unchanged unless
`LAYERSENTRY_RKE2_AIRGAP=true` is selected by the wrapper.

The image contains `/opt/install.sh`, the RKE2 tarball and checksum manifest in
`/opt/rke2-artifacts`, and the pinned core/Canal image archives in
`/var/lib/rancher/rke2/agent/images`. Every downloaded build artifact is checked
against a source-controlled SHA256 before it is installed.

The build installs and enables `qemu-guest-agent`. The OneKS `kubectl` wrapper
and `worker-disk` helper receive the SELinux `virt_qemu_ga_unconfined_exec_t`
label. `worker-disk` exposes only `status` and `grow`, validates managed mount
paths, and uses `xfs_growfs` or `resize2fs`; it does not expose a shell action.

Build from the repository root with:

```sh
packer/layersentry-poc/test-rocky-rke2-airgap.sh
packer/layersentry-poc/build-rocky-rke2-airgap.sh
```

The resulting qcow2 and SHA256 are written under `export-layersentry/` by
default. Register that qcow2 as a new OpenNebula OS image and update OneKS
`node_image_id`; do not overwrite the currently used base image.
