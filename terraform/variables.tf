variable "libvirt_uri" {
  description = "libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "vcpus" {
  description = "Default vCPUs per VM"
  type        = number
  default     = 2

  validation {
    condition     = var.vcpus >= 1
    error_message = "vcpus must be at least 1."
  }
}

variable "memory" {
  description = "Default memory per VM in MiB"
  type        = number
  default     = 4096

  validation {
    condition     = var.memory >= 1024
    error_message = "memory must be at least 1024 MiB."
  }
}

variable "root_disk_size" {
  description = "Default root disk size in GB"
  type        = number
  default     = 30

  validation {
    condition     = var.root_disk_size >= 10
    error_message = "root_disk_size must be at least 10 GB."
  }
}

variable "hypervisor_ip" {
  description = "IP address of the hypervisor host for nova-compute machine registration"
  type        = string

  validation {
    condition     = var.hypervisor_ip != ""
    error_message = "hypervisor_ip must not be empty."
  }
}

variable "hypervisor_ssh_user" {
  description = "SSH user for the hypervisor host"
  type        = string
  default     = "ubuntu"
}

variable "management_network_cidr" {
  description = "CIDR for the management NAT network"
  type        = string
  default     = "192.168.100.0/24"

  validation {
    condition     = can(cidrhost(var.management_network_cidr, 1))
    error_message = "management_network_cidr must be a valid CIDR notation."
  }
}

variable "ubuntu_image_url" {
  description = "Ubuntu Noble cloud image URL"
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "pool_name" {
  description = "libvirt storage pool name"
  type        = string
  default     = "vgpu-testing"
}

variable "pool_path" {
  description = "libvirt storage pool directory path"
  type        = string
  default     = "/var/lib/libvirt/vgpu-testing-pool"
}

variable "ssh_public_key" {
  description = "Optional additional SSH public key to authorize on VMs; a dedicated keypair is always generated regardless"
  type        = string
  default     = ""
}

variable "bootstrap_juju" {
  description = "Whether to automatically bootstrap a Juju controller"
  type        = bool
  default     = true
}

variable "juju_controller_name" {
  description = "Name for the Juju controller"
  type        = string
  default     = "vgpu-controller"
}

variable "juju_model_name" {
  description = "Name for the Juju workload model"
  type        = string
  default     = "openstack"
}

variable "deploy_openstack" {
  description = "Whether to deploy the OpenStack bundle after Juju bootstrap"
  type        = bool
  default     = true
}

variable "ovn_bridge_mappings" {
  description = "OVN bridge mappings for ovn-chassis"
  type        = string
  default     = "physnet1:br-ex"
}

variable "ovn_bridge_interface_mappings" {
  description = "Maps OVS bridge to physical interface on the hypervisor for provider network traffic"
  type        = string
  default     = "br-ex:ens6"
}

variable "vm_config_override" {
  description = "Per-VM override configuration keyed by VM name"
  type = map(object({
    vcpus          = optional(number)
    memory         = optional(number)
    root_disk_size = optional(number)
  }))
  default = {}
}
