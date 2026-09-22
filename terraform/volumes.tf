resource "libvirt_volume" "noble_base" {
  name = "noble-base"
  pool = libvirt_pool.vgpu.name

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = { url = var.ubuntu_image_url }
  }
}

resource "libvirt_volume" "vm_root" {
  for_each = local.vm_definitions

  name     = "${each.key}-root"
  pool     = libvirt_pool.vgpu.name
  capacity = each.value.root_disk * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.noble_base.path
    format = { type = "qcow2" }
  }
}
