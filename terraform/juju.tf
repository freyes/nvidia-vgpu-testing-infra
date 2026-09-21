locals {
  juju_bootstrap_script = <<-EOT
    set -euo pipefail

    # --- 1. Juju must be installed on the host running Terraform ---
    if ! command -v juju >/dev/null 2>&1; then
      echo "ERROR: juju is not installed on the host. Install it with: snap install juju --classic" >&2
      exit 1
    fi

    # --- 2. Start SSH agent and load the generated key ---
    eval "$$(ssh-agent -s)"
    trap 'kill $${SSH_AGENT_PID} 2>/dev/null || true' EXIT
    ssh-add "$${SSH_KEY_PATH}"

    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

    # --- 3. Discover the juju-controller IP via virsh domifaddr ---
    IP=""
    for attempt in $$(seq 1 30); do
      IP=$$(virsh -c "$${LIBVIRT_URI}" domifaddr "$${DOMAIN_NAME}" --source lease 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1)
      if [ -n "$${IP}" ]; then
        break
      fi
      sleep 5
    done

    if [ -z "$${IP}" ]; then
      echo "ERROR: Could not discover IP for domain $${DOMAIN_NAME} via virsh domifaddr" >&2
      exit 1
    fi
    echo "Discovered juju-controller IP: $${IP}"

    # --- 4. Wait for SSH to become reachable (up to 60 attempts, 5s apart) ---
    SSH_READY=false
    for attempt in $$(seq 1 60); do
      if ssh $${SSH_OPTS} ubuntu@"$${IP}" true 2>/dev/null; then
        SSH_READY=true
        break
      fi
      echo "Waiting for SSH on $${IP} (attempt $${attempt}/60)..."
      sleep 5
    done
    if [ "$${SSH_READY}" != "true" ]; then
      echo "ERROR: SSH never became reachable on $${IP} after 60 attempts" >&2
      exit 1
    fi
    echo "SSH is reachable on $${IP}"

    # --- 5. Wait for cloud-init to finish ---
    echo "Waiting for cloud-init to finish on $${IP}..."
    ssh $${SSH_OPTS} ubuntu@"$${IP}" cloud-init status --wait
    echo "cloud-init finished on $${IP}"

    # --- 6. Check if the controller already exists; skip bootstrap if so ---
    if juju controllers --format=json 2>/dev/null \
        | jq -e ".controllers | has(\"$${JUJU_CONTROLLER_NAME}\")" >/dev/null 2>&1; then
      echo "Controller $${JUJU_CONTROLLER_NAME} already exists, skipping bootstrap"
      juju switch "$${JUJU_CONTROLLER_NAME}"
    else
      echo "Bootstrapping controller $${JUJU_CONTROLLER_NAME} on manual/ubuntu@$${IP}"
      juju bootstrap "manual/ubuntu@$${IP}" "$${JUJU_CONTROLLER_NAME}" \
        --bootstrap-base=ubuntu@24.04
    fi

    # --- 7. Add or select the workload model ---
    if juju models --format=json 2>/dev/null \
        | jq -e ".models | any(.name == \"$${JUJU_MODEL_NAME}\")" >/dev/null 2>&1; then
      echo "Model $${JUJU_MODEL_NAME} already exists, switching to it"
      juju switch "$${JUJU_CONTROLLER_NAME}:$${JUJU_MODEL_NAME}"
    else
      echo "Adding model $${JUJU_MODEL_NAME}"
      juju add-model "$${JUJU_MODEL_NAME}"
    fi

    echo "Juju bootstrap complete: controller=$${JUJU_CONTROLLER_NAME}, model=$${JUJU_MODEL_NAME}"
  EOT
}

resource "null_resource" "juju_bootstrap" {
  count = var.bootstrap_juju ? 1 : 0

  triggers = {
    domain_name          = libvirt_domain.vgpu_vm["juju-controller"].name
    juju_controller_name = var.juju_controller_name
    juju_model_name      = var.juju_model_name
  }

  depends_on = [libvirt_domain.vgpu_vm]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      DOMAIN_NAME          = libvirt_domain.vgpu_vm["juju-controller"].name
      SSH_KEY_PATH         = abspath(local_sensitive_file.ssh_private_key.filename)
      JUJU_CONTROLLER_NAME = var.juju_controller_name
      JUJU_MODEL_NAME      = var.juju_model_name
      LIBVIRT_URI          = var.libvirt_uri
    }

    command = local.juju_bootstrap_script
  }
}

resource "null_resource" "juju_deploy" {
  count = var.deploy_openstack ? 1 : 0

  triggers = {
    hypervisor_ip                     = var.hypervisor_ip
    ovn_bridge_mappings               = var.ovn_bridge_mappings
    ovn_bridge_interface_mappings     = var.ovn_bridge_interface_mappings
  }

  depends_on = [null_resource.juju_bootstrap]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      JUJU_CONTROLLER_NAME          = var.juju_controller_name
      JUJU_MODEL_NAME               = var.juju_model_name
      HYPERVISOR_IP                 = var.hypervisor_ip
      HYPERVISOR_SSH_USER           = var.hypervisor_ssh_user
      SSH_KEY_PATH                  = abspath(local_sensitive_file.ssh_private_key.filename)
      LIBVIRT_URI                   = var.libvirt_uri
      OVN_BRIDGE_MAPPINGS           = var.ovn_bridge_mappings
      OVN_BRIDGE_INTERFACE_MAPPINGS = var.ovn_bridge_interface_mappings
      BUNDLE_TEMPLATE_PATH          = abspath("${path.module}/templates/bundle.yaml.tpl")
    }

    command = "${path.module}/../scripts/deploy-openstack.sh"
  }
}

resource "null_resource" "vault_init" {
  count = var.deploy_openstack ? 1 : 0

  triggers = {
    hypervisor_ip = var.hypervisor_ip
  }

  depends_on = [null_resource.juju_deploy]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      JUJU_MODEL           = var.juju_model_name
      JUJU_CONTROLLER_NAME = var.juju_controller_name
    }

    command = "${path.module}/../scripts/vault-unseal-and-authorise.sh"
  }
}
