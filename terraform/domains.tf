resource "libvirt_domain" "vgpu_vm" {
  for_each = local.vm_definitions

  name        = each.value.name
  type        = "kvm"
  memory      = each.value.memory
  memory_unit = "MiB"
  vcpu        = each.value.vcpus
  running     = true

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [{ dev = "hd" }]
  }

  cpu = {
    mode = "host-passthrough"
  }

  devices = {
    disks = [
      {
        source = { volume = { pool = libvirt_pool.vgpu.name, volume = libvirt_volume.vm_root[each.key].name } }
        target = { dev = "vda", bus = "virtio" }
      },
      {
        source = { file = { file = libvirt_cloudinit_disk.cloudinit[each.key].path } }
        target = { dev = "sda", bus = "sata" }
      }
    ]
    interfaces = [
      {
        model       = { type = "virtio" }
        source      = { network = { network = libvirt_network.mgmt.name } }
        wait_for_ip = { source = "lease", timeout = 300 }
      }
    ]
    consoles = [
      {
        target = { type = "serial", port = 0 }
        source = { file = { path = "/var/log/libvirt/qemu/${each.key}-console.log", append = "on" } }
      }
    ]
    graphics = [
      {
        spice = {
          auto_port = true
          listen    = "0.0.0.0"
        }
      }
    ]
  }
}
