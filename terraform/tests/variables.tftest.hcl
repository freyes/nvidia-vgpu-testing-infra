mock_provider "libvirt" {}

run "plan_succeeds_with_hypervisor_ip" {
  command = plan

  variables {
    hypervisor_ip = "192.168.1.100"
  }

  assert {
    condition     = var.hypervisor_ip == "192.168.1.100"
    error_message = "plan should succeed with hypervisor_ip set"
  }
}

run "plan_fails_without_hypervisor_ip" {
  command = plan

  variables {
    hypervisor_ip = ""
  }

  expect_failures = [var.hypervisor_ip]
}

run "plan_fails_with_invalid_vcpus" {
  command = plan

  variables {
    hypervisor_ip = "192.168.1.100"
    vcpus         = 0
  }

  expect_failures = [var.vcpus]
}

run "plan_fails_with_invalid_memory" {
  command = plan

  variables {
    hypervisor_ip = "192.168.1.100"
    memory        = 512
  }

  expect_failures = [var.memory]
}
