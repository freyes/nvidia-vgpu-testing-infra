resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "ssh_private_key" {
  content        = tls_private_key.ssh.private_key_pem
  filename       = "${path.module}/ssh_private_key"
  file_permission = "0600"
}

resource "local_file" "ssh_public_key" {
  content  = tls_private_key.ssh.public_key_openssh
  filename = "${path.module}/ssh_public_key.pub"
}

resource "libvirt_cloudinit_disk" "cloudinit" {
  for_each = local.vm_definitions

  name      = "cloudinit-${each.key}"
  user_data = templatefile("${path.module}/templates/user-data-${each.value.is_juju_controller ? "juju" : "base"}.yaml.tpl", {
    hostname           = each.key
    ssh_public_key     = tls_private_key.ssh.public_key_openssh
    additional_ssh_key = var.ssh_public_key
  })
  meta_data = yamlencode({
    instance-id    = each.key
    local-hostname = each.key
  })
}
