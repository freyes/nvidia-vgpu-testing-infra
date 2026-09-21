resource "libvirt_network" "mgmt" {
  name = "vgpu-mgmt"
  forward = {
    mode = "nat"
  }
  ips = [{
    address = cidrhost(var.management_network_cidr, 1)
    netmask = cidrnetmask(var.management_network_cidr)
    dhcp = {
      ranges = [{
        start = cidrhost(var.management_network_cidr, 10)
        end   = cidrhost(var.management_network_cidr, 250)
      }]
    }
  }]
  dns = {
    enable = "yes"
  }
}