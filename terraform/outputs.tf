resource "local_file" "testbed" {
  content = templatefile("${path.module}/templates/testbed.yaml.tpl", {
    vm_names         = keys(local.vm_definitions)
    hypervisor_ip    = var.hypervisor_ip
    ssh_private_key  = abspath(local_sensitive_file.ssh_private_key.filename)
    ssh_user         = "ubuntu"
    hypervisor_ssh_user = var.hypervisor_ssh_user
  })
  filename = "${path.module}/testbed.yaml"
}

output "vm_ips" {
  description = "Map of VM name to IP address. IPs are discovered at apply time via wait_for_ip on the domain interface; v0.9.9 does not expose interface addresses as a plan-time attribute."
  value       = { for k, v in libvirt_domain.vgpu_vm : k => "" }
}

output "juju_controller_ip" {
  description = "IP address of the juju-controller VM. Discovered at apply time via wait_for_ip; v0.9.9 does not expose interface addresses as a plan-time attribute."
  value       = { for k, v in libvirt_domain.vgpu_vm : k => "" }["juju-controller"]
}

output "ssh_private_key_path" {
  description = "Absolute path to the generated SSH private key for VM access."
  value       = abspath(local_sensitive_file.ssh_private_key.filename)
  sensitive   = true
}

output "ssh_public_key" {
  description = "Generated SSH public key authorized on all VMs."
  value       = tls_private_key.ssh.public_key_openssh
}

output "testbed_yaml_path" {
  description = "Absolute path to the generated testbed.yaml file."
  value       = abspath(local_file.testbed.filename)
}
