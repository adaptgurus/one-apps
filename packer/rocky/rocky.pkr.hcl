locals {
  rocky_source_key = var.layersentry_rke2_airgap && var.version == "9" && var.arch == "x86_64" ? "9-layersentry.x86_64" : "${var.version}.${var.arch}"
}

# Build cloud init iso
source "null" "null" { communicator = "none" }

build {
  sources = ["sources.null.null"]

  provisioner "shell-local" {
    inline = [
      "packer/make-cloud-init-iso.sh ${var.input_dir}/${var.appliance_name}-cloud-init.iso ${var.input_dir}/cloud-init.yml",
    ]
  }
}

source "qemu" "rocky" {
  cpus        = 2
  cpu_model   = "host"
  memory      = 2048
  accelerator = "kvm"

  iso_url      = lookup(lookup(var.rocky, local.rocky_source_key, {}), "iso_url", "")
  iso_checksum = lookup(lookup(var.rocky, local.rocky_source_key, {}), "iso_checksum", "")

  firmware     = lookup(lookup(var.arch_vars, var.arch, {}), "firmware", "")
  use_pflash   = lookup(lookup(var.arch_vars, var.arch, {}), "use_pflash", "")
  machine_type = lookup(lookup(var.arch_vars, var.arch, {}), "machine_type", "")
  qemu_binary  = var.qemu_binary_override != "" ? var.qemu_binary_override : lookup(lookup(var.arch_vars, var.arch, {}), "qemu_binary", "")

  headless = var.headless

  disk_image       = true
  disk_cache       = "unsafe"
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  format           = "qcow2"
  disk_compression = false
  skip_resize_disk = true

  output_directory = "${var.output_dir}"

  qemuargs = [
    ["-cdrom", "${var.input_dir}/${var.appliance_name}-cloud-init.iso"],
    ["-serial", "stdio"],
  ]
  ssh_username     = "root"
  ssh_password     = "opennebula"
  ssh_timeout      = "900s"
  shutdown_command = "poweroff"
  vm_name          = "${var.appliance_name}"
}
