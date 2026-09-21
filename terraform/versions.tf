terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "= 0.9.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "= 2.5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "= 3.2.0"
    }
  }

  required_version = ">= 1.7"
}
