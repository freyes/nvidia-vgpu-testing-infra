resource "libvirt_pool" "vgpu" {
  name   = var.pool_name
  type   = "dir"
  target = {
    path = var.pool_path
  }
}