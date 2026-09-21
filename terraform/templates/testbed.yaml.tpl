machines:
%{ for name in vm_names ~}
  - hostname: ${name}
    ip: <discovered-at-apply-time>
    roles:
      - ${name == "juju-controller" ? "controller" : "control"}
%{ endfor ~}
  - hostname: hypervisor
    ip: ${hypervisor_ip}
    roles:
      - compute
ssh:
  user: ${ssh_user}
  private_key: ${ssh_private_key}
hypervisor_ssh_user: ${hypervisor_ssh_user}
