
## T3: prepare-host.sh

- Script lives at `scripts/prepare-host.sh`, executable, `set -euo pipefail`.
- Two modes: `--check` (read-only, always exit 0) and default enforce mode
  (same checks, exit 1 on any failure).
- Six checks implemented in order: IOMMU (cmdline + non-empty
  `/sys/kernel/iommu_groups`), NVIDIA GPU (lspci OR `/sys/bus/pci/devices/*/vendor`
  == `0x10de`), libvirtd active, Juju in PATH, NVIDIA vGPU driver
  (`nvidia_vgpu_vfio` or `nvidia` in lsmod), `sriov-manage` at
  `/usr/lib/nvidia/sriov-manage`.
- Deliberately NOT done: GPU rebind to generic `vfio-pci` (NVIDIA vGPU driver
  uses its vendor-specific VFIO framework on Noble), nested-virt check
  (nova-compute runs on the hypervisor directly), GRUB edits, reboots,
  systemd/cron scheduling.
- Used `command -v` (not `which`); no `EUID` root check (this is a check script,
  not a mutation script).
- Verified in this container: all six checks FAIL as expected (no GPU, no
  IOMMU, no libvirtd, no juju, no nvidia module, no sriov-manage). `--check`
  exits 0; enforce mode exits 1.

## T4: network.tf + pool.tf

- `terraform/network.tf`: single `libvirt_network.mgmt` named `vgpu-mgmt`,
  `forward = { mode = "nat" }`, single `ips` block with `address`/`netmask`
  computed from `var.management_network_cidr` via `cidrhost`/`cidrnetmask`,
  DHCP range `.10`–`.250` (required for `wait_for_ip` on domains), `dns =
  { enable = "yes" }`.
- `terraform/pool.tf`: single `libvirt_pool.vgpu`, `type = "dir"`, `target =
  { path = var.pool_path }`, name from `var.pool_name`.
- v0.9.9 schema confirmed: `ips` (not legacy `addresses`), `forward`/`dns`/
  `target` as object blocks. No `autostart` on pool schema.
- `terraform validate` passes. Later volumes/domains MUST reference
  `libvirt_pool.vgpu.name` (not `var.pool_name`) for dependency ordering.

## T5: volumes + cloud-init

- `terraform/cloudinit.tf`: `tls_private_key.ssh` (RSA 4096, always generated),
  `local_sensitive_file.ssh_private_key` (0600), `local_file.ssh_public_key`,
  and `libvirt_cloudinit_disk.cloudinit` with `for_each = local.vm_definitions`
  (12 disks). Template selected via `each.value.is_juju_controller ? "juju" : "base"`.
- `terraform/volumes.tf`: `libvirt_volume.noble_base` (1, qcow2, downloaded via
  `create.content.url = var.ubuntu_image_url`), `libvirt_volume.vm_root`
  (12, qcow2 CoW overlay with `backing_store` pointing at noble_base),
  `libvirt_volume.cloudinit` (12, raw, content url = cloudinit disk path).
- `templates/user-data.yaml.tpl`: cloud-config with hostname, fqdn,
  ssh_authorized_keys (generated key + optional `additional_ssh_key` via
  `%{ if }`), qemu-guest-agent package + runcmd enable.
- `templates/user-data-juju.yaml.tpl`: same as base PLUS `snap.commands`
  installing juju --classic.
- v0.9.9 schema confirmed: `target.format.type`, `create.content.url`,
  `backing_store.{path,format}`. No `source` field. No ephemeral volume
  (nova-compute is on hypervisor, not a VM). No `cloud-init status --wait`
  in user-data (T8 handles wait remotely via SSH to avoid runcmd deadlock).
- `terraform validate` passes. Committed as 1900c2c.
- Did NOT touch network.tf / pool.tf (T4 in parallel — pre-existing unstaged
  changes left alone).

## T6: domains.tf

- `terraform/domains.tf`: single `libvirt_domain.vgpu_vm` with `for_each =
  local.vm_definitions` (12 domains). q35 machine, `host-passthrough` CPU,
  `hvm`/`x86_64` OS, boot from `hd`.
- Two disks: `vda` virtio (root volume from `libvirt_volume.vm_root[each.key]`
  in `libvirt_pool.vgpu`), `sda` sata (cloudinit ISO via
  `libvirt_volume.cloudinit[each.key].path`).
- Single NIC: virtio on `libvirt_network.mgmt` with `wait_for_ip = { source =
  "lease", timeout = 300 }` (numeric seconds, NOT "5m").
- v0.9.9 schema correction: `os.boot_devices` is a list of OBJECTS with required
  `dev` field — `[{ dev = "hd" }]`, NOT `["hd"]`. The task spec's literal
  `["hd"]` was wrong; schema requires objects.
- No `hostdevs` (GPU on hypervisor), no provider NIC (nova-compute on
  hypervisor), no ephemeral disk. `devices` uses nested attribute list literals,
  NOT `dynamic` blocks.
- `terraform validate` passes. Committed as 1fe018c.
- `terraform plan` cannot run in this container (no libvirtd, no
  `/var/run/libvirt/libvirt-sock`); validate + console count (12) are the
  verification gates here.

## T7: outputs + testbed.yaml + terraform test

- `terraform/outputs.tf`: `local_file.testbed` resource using `templatefile()`
  with `vm_names`, `hypervisor_ip`, `ssh_private_key` (abspath), `ssh_user`,
  `hypervisor_ssh_user`. Five outputs: `vm_ips` (map of VM name → "", references
  `libvirt_domain.vgpu_vm` directly via for comprehension), `juju_controller_ip`
  (same pattern, references resource directly), `ssh_private_key_path`
  (sensitive, abspath of `local_sensitive_file.ssh_private_key.filename`),
  `ssh_public_key` (`tls_private_key.ssh.public_key_openssh`), `testbed_yaml_path`
  (abspath of `local_file.testbed.filename`).
- v0.9.9 does NOT expose `interface.addresses` at plan time — `wait_for_ip` is
  set on the domain interface but IPs are only discovered at apply. Outputs
  return empty strings with descriptions noting IPs are discovered post-apply.
  All outputs reference resources/locals directly (no `output.*` self-references).
- `templates/testbed.yaml.tpl`: lists 12 VMs (from `keys(local.vm_definitions)`)
  + hypervisor. Each VM gets `hostname`, `ip: <discovered-at-apply-time>`, and
  `roles: [controller|control]` (juju-controller → controller, all others →
  control). Hypervisor gets `roles: [compute]`. SSH block with user + private_key
  abspath + hypervisor_ssh_user.
- `tests/variables.tftest.hcl`: `mock_provider "libvirt" {}` (empty block,
  Terraform 1.7+). Four `run` blocks with `command = plan`: (1) plan succeeds
  with `hypervisor_ip = "192.168.1.100"`, asserts variable is set; (2) plan
  fails with `hypervisor_ip = ""` via `expect_failures = [var.hypervisor_ip]`;
  (3) plan fails with `vcpus = 0`; (4) plan fails with `memory = 512`.
- **Pre-existing bug fix from T5**: `cloudinit.tf` references
  `user-data-${... ? "juju" : "base"}.yaml.tpl` but the base template was named
  `user-data.yaml.tpl`. Renamed to `user-data-base.yaml.tpl` to match. This
  blocked `terraform test` because `templatefile()` is evaluated at plan time
  even with `mock_provider` and `override_resource` — the function runs before
  the mock/override applies.
- **Added validation rule to `hypervisor_ip`**: `condition = var.hypervisor_ip != ""`.
  Required for `expect_failures = [var.hypervisor_ip]` to work — `expect_failures`
  only catches validation rule failures, not "No value for required variable"
  errors. Test provides `hypervisor_ip = ""` so the validation runs and fails.
- `terraform validate` passes. `terraform test` passes (4/4). Committed as 4016261.

## T8: Juju bootstrap automation (juju.tf)

- `terraform/juju.tf`: `null_resource.juju_bootstrap` with `count = var.bootstrap_juju ? 1 : 0`,
  `depends_on = [libvirt_domain.vgpu_vm]`, `triggers` keyed on
  `libvirt_domain.vgpu_vm["juju-controller"].name` + `var.juju_controller_name` +
  `var.juju_model_name`. `local-exec` provisioner with `interpreter = ["/bin/bash", "-c"]`,
  `environment` block passing DOMAIN_NAME, SSH_KEY_PATH (abspath of
  `local_sensitive_file.ssh_private_key.filename`), JUJU_CONTROLLER_NAME, JUJU_MODEL_NAME,
  LIBVIRT_URI. Script stored in `local.juju_bootstrap_script` heredoc.
- Script flow: (1) `command -v juju` check → fail with install hint; (2) ssh-agent + ssh-add
  generated key (trap EXIT to kill agent); (3) IP discovery via `virsh -c $LIBVIRT_URI
  domifaddr $DOMAIN_NAME --source lease` + grep for IPv4 (up to 30 attempts, 5s); (4) SSH
  wait (up to 60 attempts, 5s, ConnectTimeout=10, BatchMode via StrictHostKeyChecking=no);
  (5) `cloud-init status --wait` over SSH; (6) check if controller exists via
  `juju controllers --format=json | jq -e '.controllers | has(name)'` → skip or bootstrap
  with `juju bootstrap "manual/ubuntu@$IP" $NAME --bootstrap-base=ubuntu@24.04` (Juju 3.x);
  (7) `juju add-model` or `juju switch` if model exists.
- **Heredoc escaping**: Terraform heredocs (`<<-EOT`) treat `${...}` as interpolation. ALL
  shell `$` must be escaped as `$$` to produce literal `$` in the rendered script. This is
  the standard Terraform pattern for embedding bash in heredocs — `$$` → `$` at render time.
- `variables.tf`: Added validation to `deploy_openstack`:
  `condition = !(var.deploy_openstack && !var.bootstrap_juju)`, error message
  "deploy_openstack requires bootstrap_juju=true." Variable validation CAN reference other
  variables in Terraform 1.7+.
- `tests/juju_bootstrap.tftest.hcl`: 3 new test runs with `mock_provider "libvirt" {}` +
  `mock_provider "null" {}`: (1) bootstrap_juju=true → length(null_resource.juju_bootstrap)==1;
  (2) bootstrap_juju=false, deploy_openstack=false → length==0; (3) bootstrap_juju=false,
  deploy_openstack=true → expect_failures=[var.deploy_openstack]. All 7 tests pass (4
  existing + 3 new). `terraform validate` passes.
- `terraform plan` cannot run in this container (no libvirtd); `terraform test` with mock
  providers is the verification gate. Committed as a448321.

## T9: OpenStack bundle deployment (bundle.yaml.tpl, deploy-openstack.sh, juju.tf)

- `terraform/templates/bundle.yaml.tpl`: Juju bundle YAML with `series: noble`, 12 machine
  entries (IDs 1-11 for control-plane VMs + `hypervisor` for the hypervisor host). 19
  applications: mysql-innodb-cluster (3 units, mem=3072M, machines 1-3), rabbitmq-server
  (1 unit, machine 4), keystone (machine 5), glance (machine 6), nova-cloud-controller
  (machine 7), placement (machine 8), neutron-api (machine 9, manage-neutron-plugin-legacy-mode:
  false, flat-network-providers: physnet1, neutron-security-groups: true), ovn-central
  (machine 10, source: distro), vault (machine 11), nova-compute (machine hypervisor,
  enable-live-migration: false), nova-compute-nvidia-vgpu (subordinate, vgpu-mode: auto),
  ovn-chassis (subordinate, ovn-bridge-mappings + bridge-interface-mappings from template
  vars), neutron-api-plugin-ovn (subordinate), 6 mysql-router subordinates. All charms
  `channel: latest/edge`, `series: noble`. 38 relations covering amqp, identity-service,
  cloud-compute, image-service, certificates (vault TLS for all API endpoints + OVN),
  shared-db/db-router (mysql-router per service → mysql-innodb-cluster), OVN
  ovsdb-cms/ovsdb, neutron-plugin, nova-vgpu.
- Template uses `${ovn_bridge_mappings}` and `${ovn_bridge_interface_mappings}` — rendered
  by `envsubst` in the deploy script (NOT Terraform's templatefile, because the deploy
  script handles rendering at runtime, not at plan time). `envsubst` with explicit var
  list to only substitute those two variables.
- `scripts/deploy-openstack.sh`: `#!/bin/bash`, `set -euo pipefail`, `--dry-run` flag.
  Reads 9 env vars (all required via `${VAR:?}`). Flow: (1) parse --dry-run; (2) read env
  vars; (3) ssh-agent + ssh-add key (trap EXIT kills agent); (4) discover 11 VM IPs via
  `virsh -c $LIBVIRT_URI domifaddr <domain> --source lease` (30 attempts, 5s apart, grep
  IPv4); (5) wait for Juju controller readiness via `juju status -m controller:model`
  (30 attempts, 10s apart); (6) render bundle via envsubst to `.tpl`-stripped path; (7) if
  dry-run, exit after render; (8) register 11 VMs + hypervisor as manual machines via
  `juju add-machine -m ... ssh:user@ip --private-key=...` — idempotent via
  `get_machine_id_by_ip()` which queries `juju machines --format=json` and checks
  instance-id/hostname for the IP; (9) build `--map-machines=existing,...` argument with
  explicit mappings where bundle ID != Juju ID (hypervisor always needs explicit mapping
  since its bundle machine ID is the non-numeric string "hypervisor"); (10) `juju deploy
  -m ... bundle.yaml --trust --map-machines=$MAP_ARG`.
- VM domain order in script matches bundle machine IDs 1-11: mysql-0, mysql-1, mysql-2,
  rabbitmq, keystone, glance, nova-cloud-controller, placement, neutron-api, ovn-central,
  vault. In a fresh model, `juju add-machine` assigns IDs 1-11 in order, so the identity
  mapping works for control-plane VMs. Only the hypervisor needs `hypervisor=<juju_id>`.
- `terraform/juju.tf`: added `null_resource.juju_deploy` with `count = var.deploy_openstack
  ? 1 : 0`, `depends_on = [null_resource.juju_bootstrap]`, `triggers` keyed on
  `var.hypervisor_ip`, `var.ovn_bridge_mappings`, `var.ovn_bridge_interface_mappings`.
  `local-exec` provisioner with `interpreter = ["/bin/bash", "-c"]`, environment block
  passing all 9 env vars (SSH_KEY_PATH and BUNDLE_TEMPLATE_PATH via abspath()), command
  runs `${path.module}/../scripts/deploy-openstack.sh`.
- NO `juju config` or `juju run` in the deploy script (per MUST NOT DO). NO individual
  charm deployments — only `juju deploy bundle.yaml`. NO sed for machine numbers — uses
  `--map-machines=existing` with the `machines:` section. NO deployment to controller
  model — uses `-m ${JUJU_CONTROLLER_NAME}:${JUJU_MODEL_NAME}`. NO VM for nova-compute —
  it's on the hypervisor machine.
- `terraform validate` passes. `bash -n` on deploy script passes. Bundle renders correctly
  via envsubst (verified OVN variables substituted). 19 applications, 38 relations, all
  channels latest/edge, all series noble. Committed.

## T10: Vault unseal and authorize-charm (vault-unseal-and-authorise.sh, juju.tf)

- `scripts/vault-unseal-and-authorise.sh`: `#!/bin/bash`, `set -euo pipefail`, self-contained
  (NO sourcing of juju_helpers or any external helpers). Adapted from
  https://github.com/canonical/stsstack-bundles/blob/main/tools/vault-unseal-and-authorise.sh.
- Env vars: `JUJU_MODEL` (default: `openstack`), `JUJU_CONTROLLER_NAME` (default:
  `vgpu-controller`). Note: script uses `JUJU_MODEL` (NOT `JUJU_MODEL_NAME` like
  deploy-openstack.sh) — the terraform provisioner maps `var.juju_model_name` → `JUJU_MODEL`.
- Dependency install: `command -v vault > /dev/null 2>&1 || sudo snap install vault` and
  `command -v jq > /dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y jq; }`
  (uses `command -v` NOT `which`; uses `{ ...; }` group for proper precedence with `||`).
- Model name/UUID: `juju show-model --format=json | jq -r '. | keys[]'` and
  `juju show-model --format=json | jq -r '.[]."model-uuid"'`. Relies on current model
  context being set (from juju_bootstrap's `juju switch`/`juju add-model`).
- `umask 077` set before creating unseal file. Path: `unseal_output="${HOME}/unseal_output.${model}"`.
  File is NOT auto-deleted (contains root token).
- Vault unit addresses/leader from `juju status -m "$MODEL" --format=json vault`. Uses
  `readarray -t addrs < <(jq ...)` (process substitution, NOT here-string) to avoid empty
  array element when jq returns nothing. `select(. != null)` filters null addresses.
- Idempotency via `vault status` exit codes: 0 = unsealed, 1 = sealed, 2 = uninitialized.
  `set +e` / `vault status` / capture rc / `set -e` pattern to handle non-zero exit codes
  under `set -e`. Init only if rc==2. Unseal only if rc==1. Skip if rc==0.
- Init: `echo "$model_uuid" > "$unseal_output"`, `chmod 600 "$unseal_output"`,
  `vault operator init -key-shares=5 -key-threshold=3 &>> "$unseal_output"` (append mode
  for both stdout+stderr). File contains model_uuid on first line, then keys + token.
- Unseal keys extracted via `sed -r 's/Unseal Key N: (.+)/\1/g;t;d'` and token via
  `sed -r 's/Initial Root Token: (.+)/\1/g;t;d'`. The `t;d` pattern: `t` branches to end
  if `s` matched (print replacement), `d` deletes non-matching lines.
- Authorize-charm: `juju run -m "$MODEL" vault/leader authorize-charm token="$token"`
  (Juju 3.x syntax, NOT `juju run-action`, NOT `juju $JUJU_RUN_CMD`). Always runs
  (charm handles idempotency). Token from unseal_output file (persists between runs).
- `terraform/juju.tf`: `null_resource.vault_init` with `count = var.deploy_openstack ? 1 : 0`,
  `depends_on = [null_resource.juju_deploy]`, `triggers = { hypervisor_ip = var.hypervisor_ip }`
  (re-runs only if hypervisor IP changes). `local-exec` provisioner with
  `interpreter = ["/bin/bash", "-c"]`, environment `JUJU_MODEL = var.juju_model_name`,
  `JUJU_CONTROLLER_NAME = var.juju_controller_name`, command runs
  `${path.module}/../scripts/vault-unseal-and-authorise.sh`. All Juju commands run locally
  on the Terraform host (NOT via SSH to a VM).
- `bash -n` passes. `terraform validate` passes. `terraform test` passes (7/7).
  Committed as b6bd997.
