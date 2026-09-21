#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
ssh_authorized_keys:
  - ${ssh_public_key}
%{ if additional_ssh_key != "" }
  - ${additional_ssh_key}
%{ endif }
packages:
  - qemu-guest-agent
snap:
  commands:
    - snap install juju --classic
runcmd:
  - systemctl enable --now qemu-guest-agent
