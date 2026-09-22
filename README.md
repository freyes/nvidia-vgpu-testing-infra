# nvidia-vgpu-testing-infra

Terraform automation that provisions a minimal Charmed OpenStack environment
suitable for testing `nova-compute-nvidia-vgpu`. The infrastructure consists
of 12 Ubuntu Noble libvirt VMs for the OpenStack control plane and a Juju
controller, while **nova-compute runs directly on the hypervisor** — where
the NVIDIA GPU already lives, avoiding nested virtualization and PCI
passthrough complexity.

A single `terraform apply` creates the VMs, bootstraps a Juju controller,
deploys the OpenStack bundle (with OVN networking and the nvidia-vgpu
subordinate charm), and initialises Vault for OVN TLS certificates.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Hypervisor (bare metal)                            │
│                                                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ VM: juju    │  │ VM: mysql-0 │  │ VM: mysql-1 │  │
│  │ controller  │  │             │  │             │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ VM: mysql-2 │  │ VM: rabbit  │  │ VM: keystone│  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ VM: glance  │  │ VM: nova-cc │  │ VM: place-  │  │
│  │             │  │             │  │ ment        │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ VM: neutron │  │ VM: ovn-   │  │ VM: vault  │  │
│  │ api         │  │ central    │  │             │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │ nova-compute (Juju machine, NOT a VM)         │    │
│  │  ├── ovn-chassis (subordinate)               │    │
│  │  ├── nova-compute-nvidia-vgpu (subordinate)  │    │
│  │  └── NVIDIA GPU (already on the host)        │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  libvirt NAT network: 192.168.100.0/24 (mgmt)       │
│  libvirt storage pool: vgpu-testing (dir)           │
└─────────────────────────────────────────────────────┘
```

All 12 VMs are on a single libvirt NAT network (management). nova-compute
runs on the hypervisor itself and uses the hypervisor's physical network
interface for OVN provider network traffic.

## Prerequisites

### On the hypervisor

- **Ubuntu 24.04 (Noble)** with:
  - `libvirt` and `virsh` installed, `libvirtd` service running
  - IOMMU enabled in the kernel command line (`intel_iommu=on iommu=pt`
    or `amd_iommu=on iommu=pt`)
  - An **NVIDIA GPU with vGPU support** (e.g. A16, A30, A40, A100) and the
    NVIDIA vGPU driver installed (`nvidia-vgpu-mgr` running)
  - `sriov-manage` tool available at `/usr/lib/nvidia/sriov-manage`
  - Sufficient CPU, memory, and disk for 12 VMs (see
    [Sizing](#sizing) below)

### On the machine running Terraform (may be the hypervisor)

- **Terraform** >= 1.7 (required for `mock_provider` in tests)
- **Juju** >= 3.x (`snap install juju --classic`)
- **vault** CLI (`snap install vault`)
- **jq** (`apt install jq`)
- **virsh** (libvirt client tools, for IP discovery during apply)

### Verify prerequisites

```bash
scripts/prepare-host.sh --check
```

This checks IOMMU support, NVIDIA GPU presence, libvirtd status, Juju
availability, NVIDIA vGPU driver, and the `sriov-manage` tool without
making any changes.

## Quick start

```bash
# 1. Verify the hypervisor is ready
scripts/prepare-host.sh --check

# 2. Initialize Terraform
make init

# 3. Review the plan (hypervisor_ip is required)
make plan -var='hypervisor_ip=192.168.1.50'

# 4. Apply — creates VMs, bootstraps Juju, deploys OpenStack, inits Vault
make apply -var='hypervisor_ip=192.168.1.50'

# 5. Monitor the deployment
juju status -m vgpu-controller:openstack
```

The entire deployment is automated by three `null_resource` blocks in
`terraform/juju.tf`:

1. **`null_resource.juju_bootstrap`** — bootstraps a Juju controller on
   the `juju-controller` VM using `juju bootstrap manual/ubuntu@<ip>`,
   then creates the `openstack` workload model.
2. **`null_resource.juju_deploy`** — registers the 11 control-plane VMs
   and the hypervisor as manual Juju machines, then runs
   `juju deploy bundle.yaml --trust --map-machines=existing`.
3. **`null_resource.vault_init`** — initialises Vault (`vault operator
   init`), unseals all units, and runs `authorize-charm` to grant the
   charm access to Vault for OVN TLS certificate issuance.

All three are gated by variables and can be toggled off (see
[Variables](#variables)).

## Sizing

Default VM sizing is intentionally minimal (2 vCPUs, 4 GiB RAM, 30 GB
root disk per VM). With 12 VMs this requires at minimum:

| Resource   | Minimum (defaults) | Recommended |
|------------|-------------------|------------|
| vCPUs      | 24                | 48+        |
| Memory     | 48 GiB            | 96+ GiB    |
| Disk       | 360 GB            | 500+ GB    |

Override per-VM resources with the `vm_config_override` variable (see
[Variables](#variables)).

## Variables

All variables are defined in `terraform/variables.tf`. Required variables
must be set via `-var` or a `terraform.tfvars` file.

### Required

| Variable         | Description                                          | Type   |
|------------------|------------------------------------------------------|--------|
| `hypervisor_ip`  | IP address of the hypervisor for nova-compute machine registration | string |

### Optional with defaults

| Variable                          | Description                                              | Default       |
|-----------------------------------|----------------------------------------------------------|---------------|
| `libvirt_uri`                     | libvirt connection URI                                    | `qemu:///system` |
| `vcpus`                           | Default vCPUs per VM (min 1)                              | `2`           |
| `memory`                          | Default memory per VM in MiB (min 1024)                   | `4096`        |
| `root_disk_size`                  | Default root disk size in GB (min 10)                    | `30`          |
| `hypervisor_ssh_user`             | SSH user for the hypervisor host                         | `ubuntu`      |
| `management_network_cidr`         | CIDR for the management NAT network                      | `192.168.100.0/24` |
| `ubuntu_image_url`                | Ubuntu Noble cloud image URL                             | cloud-images.ubuntu.com Noble 24.04 |
| `pool_name`                       | libvirt storage pool name                                | `vgpu-testing` |
| `pool_path`                       | libvirt storage pool directory path                      | `/var/lib/libvirt/vgpu-testing-pool` |
| `ssh_public_key`                  | Additional SSH public key (a keypair is always generated) | `""`         |
| `bootstrap_juju`                  | Auto-bootstrap a Juju controller                         | `true`        |
| `juju_controller_name`            | Name for the Juju controller                             | `vgpu-controller` |
| `juju_model_name`                 | Name for the Juju workload model                         | `openstack`   |
| `deploy_openstack`                | Deploy the OpenStack bundle after bootstrap              | `true`        |
| `ovn_bridge_mappings`             | OVN bridge mappings for ovn-chassis                      | `physnet1:br-ex` |
| `ovn_bridge_interface_mappings`   | OVS bridge to physical interface on hypervisor           | `br-ex:ens6`  |
| `vm_config_override`              | Per-VM override map (see below)                          | `{}`          |

### Per-VM overrides

Individual VMs can be sized differently using `vm_config_override`. The
keys are the VM names defined in `terraform/locals.tf`:

`juju-controller`, `mysql-0`, `mysql-1`, `mysql-2`, `rabbitmq`,
`keystone`, `glance`, `nova-cloud-controller`, `placement`,
`neutron-api`, `ovn-central`, `vault`

Example `terraform.tfvars`:

```hcl
hypervisor_ip = "192.168.1.50"

vm_config_override = {
  "mysql-0"               = { memory = 6144, vcpus = 4 }
  "mysql-1"               = { memory = 6144, vcpus = 4 }
  "mysql-2"               = { memory = 6144, vcpus = 4 }
  "nova-cloud-controller" = { memory = 8192, vcpus = 4 }
  "neutron-api"           = { memory = 8192, vcpus = 4 }
}
```

## OpenStack bundle

The bundle is rendered from `terraform/templates/bundle.yaml.tpl` and
deployed with `juju deploy --trust --map-machines=existing`. It defines:

### Principal applications (one unit per VM)

| Application             | VM              | Machine ID | Options                          |
|------------------------|-----------------|------------|----------------------------------|
| mysql-innodb-cluster   | mysql-0/1/2     | 1, 2, 3    | `constraints: mem=3072M`         |
| rabbitmq-server        | rabbitmq        | 4          |                                  |
| keystone               | keystone        | 5          | `openstack-origin: distro`       |
| glance                 | glance          | 6          | `openstack-origin: distro`        |
| nova-cloud-controller  | nova-cloud-ctrl | 7          | `network-manager: Neutron`        |
| placement              | placement       | 8          | `openstack-origin: distro`        |
| neutron-api            | neutron-api     | 9          | `manage-neutron-plugin-legacy-mode: false` |
| ovn-central            | ovn-central     | 10         | `source: distro`                 |
| vault                  | vault           | 11         |                                  |
| nova-compute           | hypervisor       | hypervisor | `openstack-origin: distro`, `enable-live-migration: false` |

### Subordinate applications

| Application               | Relates to          | Options                              |
|---------------------------|---------------------|--------------------------------------|
| nova-compute-nvidia-vgpu  | nova-compute        | `vgpu-mode: auto`                    |
| ovn-chassis               | nova-compute        | `ovn-bridge-mappings`, `bridge-interface-mappings` |
| neutron-api-plugin-ovn    | neutron-api         |                                      |
| mysql-router (x6)         | each DB app         |                                      |

All charms use `channel: latest/edge` and `series: noble`.

### Networking

- **Management network**: libvirt NAT (`192.168.100.0/24` by default) with
  DHCP. All 12 VMs are attached. The Juju controller, control-plane charms,
  and nova-compute communicate over this network.
- **Provider network**: OVN `physnet1` mapped to `br-ex` on the hypervisor.
  The `ovn-chassis` charm configures `ovn-bridge-mappings` and
  `bridge-interface-mappings` to connect the OVS bridge to the
  hypervisor's physical interface (default `br-ex:ens6`). Override these
  with the `ovn_bridge_mappings` and `ovn_bridge_interface_mappings`
  variables.

## Scripts

### `scripts/prepare-host.sh`

Checks hypervisor prerequisites for running nova-compute with NVIDIA vGPU.
Run with `--check` for a read-only status report.

Checks:
- IOMMU enabled (kernel cmdline + `/sys/kernel/iommu_groups/`)
- NVIDIA GPU present (`lspci` or PCI vendor `0x10de`)
- `libvirtd` service active
- Juju installed (`command -v juju`)
- NVIDIA vGPU driver loaded (`lsmod | grep nvidia`)
- `sriov-manage` tool at `/usr/lib/nvidia/sriov-manage`

Does NOT rebind the GPU to `vfio-pci` — the NVIDIA vGPU driver uses a
vendor-specific VFIO framework on Noble. Does NOT auto-reboot or edit
GRUB.

### `scripts/deploy-openstack.sh`

Deploys the OpenStack bundle after Juju bootstrap. Accepts `--dry-run` to
render the bundle without deploying.

Workflow:
1. Discovers 11 control-plane VM IPs via `virsh domifaddr`
2. Waits for Juju controller readiness
3. Registers 11 VMs + the hypervisor as manual Juju machines (idempotent —
   checks `juju machines` by IP before adding)
4. Renders the bundle from the template (envsubst for OVN variables)
5. Runs `juju deploy --trust --map-machines=existing`

Does NOT run `juju config` or `juju run` after deployment — all
configuration is defined in the bundle.

### `scripts/vault-unseal-and-authorise.sh`

Initialises Vault, unseals all units, and authorizes the charm. Adapted
from
[stsstack-bundles](https://github.com/canonical/stsstack-bundles/blob/main/tools/vault-unseal-and-authorise.sh).

Workflow:
1. Installs `vault` CLI and `jq` if missing
2. Discovers the Vault leader unit and all unit addresses via
   `juju status --format=json`
3. Checks `vault status` — initialises only if uninitialized, unseals
   only if sealed (idempotent)
4. Extracts unseal keys and root token from the unseal output file
5. Unseals all Vault units with 3 of 5 keys
6. Runs `juju run vault/leader authorize-charm token=$token`

The unseal output file (`~/unseal_output.<model>`) contains the root token
and unseal keys. It is protected with `chmod 600` and `umask 077`. Keep it
safe.

## Make targets

| Target    | Command                              |
|-----------|--------------------------------------|
| `init`    | `terraform -chdir=terraform init`    |
| `plan`    | `terraform -chdir=terraform plan`    |
| `apply`   | `terraform -chdir=terraform apply -auto-approve` |
| `destroy` | `terraform -chdir=terraform destroy -auto-approve` |
| `fmt`     | `terraform -chdir=terraform fmt -recursive` |
| `validate`| `terraform -chdir=terraform validate` |
| `test`    | `terraform -chdir=terraform test`    |

## Testing

Terraform tests use `mock_provider` so they run without a libvirt daemon:

```bash
make test
```

Tests verify:
- Plan succeeds with `hypervisor_ip` set
- Plan fails without `hypervisor_ip` (required variable)
- Plan fails with `vcpus = 0` (validation)
- Plan fails with `memory = 512` (validation)
- `bootstrap_juju = true` creates 1 null_resource
- `bootstrap_juju = false` creates 0 null_resources
- `deploy_openstack = true` with `bootstrap_juju = false` fails validation

## Disabling automation steps

To create only the VMs without Juju/OpenStack/Vault:

```bash
make apply -var='hypervisor_ip=192.168.1.50' \
           -var='bootstrap_juju=false' \
           -var='deploy_openstack=false'
```

To create VMs and bootstrap Juju but skip OpenStack deployment:

```bash
make apply -var='hypervisor_ip=192.168.1.50' \
           -var='deploy_openstack=false'
```

Note: `deploy_openstack = true` requires `bootstrap_juju = true` (enforced
by variable validation).

## Cleanup

```bash
make destroy -var='hypervisor_ip=192.168.1.50'
```

This destroys all Terraform-managed resources: VMs, volumes, network,
pool, and the null_resources. Juju state on the hypervisor and the
Juju controller VM is NOT automatically cleaned up — remove the Juju
controller manually if needed:

```bash
juju destroy-controller --destroy-all-models vgpu-controller
```

## Repository structure

```
nvidia-vgpu-testing-infra/
├── README.md                        # this file
├── .gitignore
├── Makefile                         # terraform wrapper targets
├── terraform/
│   ├── versions.tf                  # provider pins (libvirt = 0.9.9)
│   ├── providers.tf                 # libvirt provider config
│   ├── variables.tf                 # all variables with descriptions
│   ├── locals.tf                    # vm_definitions map (12 VMs)
│   ├── network.tf                   # libvirt NAT network (mgmt)
│   ├── pool.tf                      # libvirt dir storage pool
│   ├── volumes.tf                   # base image + per-VM root + cloudinit volumes
│   ├── cloudinit.tf                 # SSH key + 12 per-VM cloudinit disks
│   ├── domains.tf                   # 12 libvirt domains (for_each)
│   ├── juju.tf                      # null_resource: bootstrap, deploy, vault_init
│   ├── outputs.tf                   # vm_ips, ssh keys, testbed.yaml
│   ├── templates/
│   │   ├── user-data-base.yaml.tpl  # cloud-init for control-plane VMs
│   │   ├── user-data-juju.yaml.tpl  # cloud-init for juu-controller (adds juju snap)
│   │   ├── testbed.yaml.tpl         # Juju manual provider machine list
│   │   └── bundle.yaml.tpl          # OpenStack bundle (OVN + nvidia-vgpu)
│   └── tests/
│       ├── variables.tftest.hcl     # variable validation tests
│       └── juju_bootstrap.tftest.hcl # null_resource count tests
└── scripts/
    ├── prepare-host.sh              # hypervisor prerequisite checks
    ├── deploy-openstack.sh          # machine registration + bundle deploy
    └── vault-unseal-and-authorise.sh # vault init + unseal + authorize-charm
```

## License

This project is provided as-is for testing purposes. No license is
claimed — adapt and use freely.
