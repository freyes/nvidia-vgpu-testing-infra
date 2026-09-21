mock_provider "libvirt" {}
mock_provider "null" {}

run "bootstrap_juju_true_creates_null_resource" {
  command = plan

  variables {
    hypervisor_ip   = "192.168.1.100"
    bootstrap_juju  = true
  }

  assert {
    condition     = length(null_resource.juju_bootstrap) == 1
    error_message = "null_resource.juju_bootstrap should have 1 instance when bootstrap_juju=true"
  }
}

run "bootstrap_juju_false_skips_null_resource" {
  command = plan

  variables {
    hypervisor_ip   = "192.168.1.100"
    bootstrap_juju  = false
    deploy_openstack = false
  }

  assert {
    condition     = length(null_resource.juju_bootstrap) == 0
    error_message = "null_resource.juju_bootstrap should have 0 instances when bootstrap_juju=false"
  }
}

run "deploy_openstack_requires_bootstrap_juju" {
  command = plan

  variables {
    hypervisor_ip    = "192.168.1.100"
    bootstrap_juju    = false
    deploy_openstack  = true
  }

  expect_failures = [var.deploy_openstack]
}
