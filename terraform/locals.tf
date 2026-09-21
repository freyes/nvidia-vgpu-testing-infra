locals {
  vm_defaults = {
    juju-controller       = { name = "juju-controller", role = "controller", is_juju_controller = true }
    mysql-0               = { name = "mysql-0", role = "control", is_juju_controller = false }
    mysql-1               = { name = "mysql-1", role = "control", is_juju_controller = false }
    mysql-2               = { name = "mysql-2", role = "control", is_juju_controller = false }
    rabbitmq             = { name = "rabbitmq", role = "control", is_juju_controller = false }
    keystone              = { name = "keystone", role = "control", is_juju_controller = false }
    glance                = { name = "glance", role = "control", is_juju_controller = false }
    nova-cloud-controller = { name = "nova-cloud-controller", role = "control", is_juju_controller = false }
    placement             = { name = "placement", role = "control", is_juju_controller = false }
    neutron-api          = { name = "neutron-api", role = "control", is_juju_controller = false }
    ovn-central           = { name = "ovn-central", role = "control", is_juju_controller = false }
    vault                 = { name = "vault", role = "control", is_juju_controller = false }
  }

  vm_definitions = {
    for k, v in local.vm_defaults : k => merge(v, {
      vcpus     = coalesce(try(var.vm_config_override[k].vcpus, null), var.vcpus)
      memory    = coalesce(try(var.vm_config_override[k].memory, null), var.memory)
      root_disk = coalesce(try(var.vm_config_override[k].root_disk_size, null), var.root_disk_size)
    })
  }
}
