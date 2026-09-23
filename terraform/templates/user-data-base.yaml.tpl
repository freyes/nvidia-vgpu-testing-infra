#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
ssh_pwauth: true
chpasswd:
  list: |
    ubuntu:$6$MalOPvVV6H97nswK$3xn0IzjyUMhCGv69GRjveptYPWz.FFyRvsU9m2attqr2n4TrRHlHNft2RYHy6MIqWwH.24b1fzRzasOVMAI9O0
  expire: false
  hash: true
ssh_authorized_keys:
  - ${ssh_public_key}
%{ if additional_ssh_key != "" }
  - ${additional_ssh_key}
%{ endif }
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
