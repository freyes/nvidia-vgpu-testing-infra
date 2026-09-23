#!/bin/bash
# deploy-openstack.sh — register manual machines and deploy the charmed
# OpenStack bundle onto them.
#
# Usage:
#   deploy-openstack.sh             # register machines + deploy bundle
#   deploy-openstack.sh --dry-run   # render bundle only, skip deployment
#
# Environment variables (all required):
#   JUJU_CONTROLLER_NAME            Juju controller name
#   JUJU_MODEL_NAME                 Juju workload model name
#   HYPERVISOR_IP                    IP of the hypervisor host
#   HYPERVISOR_SSH_USER              SSH user for the hypervisor
#   SSH_KEY_PATH                     Path to the private SSH key
#   LIBVIRT_URI                      libvirt connection URI
#   OVN_BRIDGE_MAPPINGS              ovn-chassis ovn-bridge-mappings value
#   OVN_BRIDGE_INTERFACE_MAPPINGS   ovn-chassis bridge-interface-mappings value
#   BUNDLE_TEMPLATE_PATH            Path to bundle.yaml.tpl
set -euo pipefail

# --- 1. Parse --dry-run flag ---
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--dry-run]" >&2
    exit 2
fi

# --- 2. Read environment variables ---
JUJU_CONTROLLER_NAME="${JUJU_CONTROLLER_NAME:?JUJU_CONTROLLER_NAME is required}"
JUJU_MODEL_NAME="${JUJU_MODEL_NAME:?JUJU_MODEL_NAME is required}"
HYPERVISOR_IP="${HYPERVISOR_IP:?HYPERVISOR_IP is required}"
HYPERVISOR_SSH_USER="${HYPERVISOR_SSH_USER:?HYPERVISOR_SSH_USER is required}"
SSH_KEY_PATH="${SSH_KEY_PATH:?SSH_KEY_PATH is required}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:?SSH_PUBLIC_KEY_PATH is required}"
LIBVIRT_URI="${LIBVIRT_URI:?LIBVIRT_URI is required}"
OVN_BRIDGE_MAPPINGS="${OVN_BRIDGE_MAPPINGS:?OVN_BRIDGE_MAPPINGS is required}"
OVN_BRIDGE_INTERFACE_MAPPINGS="${OVN_BRIDGE_INTERFACE_MAPPINGS:?OVN_BRIDGE_INTERFACE_MAPPINGS is required}"
BUNDLE_TEMPLATE_PATH="${BUNDLE_TEMPLATE_PATH:?BUNDLE_TEMPLATE_PATH is required}"

MODEL="${JUJU_CONTROLLER_NAME}:${JUJU_MODEL_NAME}"

# 11 control-plane VM domains (excluding juju-controller), ordered to match
# bundle machine IDs 1-11.
VM_DOMAINS=(
    "mysql-0"               # → bundle machine 1
    "mysql-1"               # → bundle machine 2
    "mysql-2"               # → bundle machine 3
    "rabbitmq"              # → bundle machine 4
    "keystone"              # → bundle machine 5
    "glance"                # → bundle machine 6
    "nova-cloud-controller" # → bundle machine 7
    "placement"             # → bundle machine 8
    "neutron-api"           # → bundle machine 9
    "ovn-central"            # → bundle machine 10
    "vault"                 # → bundle machine 11
)

# --- 3. Start SSH agent and load the key ---
eval "$(ssh-agent -s)"
trap 'kill $SSH_AGENT_PID 2>/dev/null || true' EXIT
ssh-add "$SSH_KEY_PATH" 2>/dev/null || true

# --- 4. Discover VM IPs via virsh domifaddr ---
echo "=== Discovering control-plane VM IPs ==="
declare -A VM_IPS
for domain in "${VM_DOMAINS[@]}"; do
    ip=""
    for attempt in $(seq 1 30); do
        ip=$(virsh -c "$LIBVIRT_URI" domifaddr "$domain" --source lease 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
            | head -1)
        if [ -n "$ip" ]; then
            break
        fi
        sleep 5
    done
    if [ -z "$ip" ]; then
        echo "ERROR: Could not discover IP for domain $domain" >&2
        exit 1
    fi
    VM_IPS["$domain"]="$ip"
    echo "  $domain: $ip"
done

# --- 5. Wait for Juju controller readiness ---
echo "=== Waiting for Juju controller readiness ==="
CONTROLLER_READY=false
for attempt in $(seq 1 30); do
    if juju status -m "$MODEL" >/dev/null 2>&1; then
        CONTROLLER_READY=true
        break
    fi
    echo "  Waiting (attempt $attempt/30)..."
    sleep 10
done
if [ "$CONTROLLER_READY" != "true" ]; then
    echo "ERROR: Juju controller not ready after 30 attempts" >&2
    exit 1
fi
echo "  Juju controller is ready"

# --- 6. Render the bundle from the template ---
echo "=== Rendering bundle ==="
BUNDLE_OUTPUT="${BUNDLE_TEMPLATE_PATH%.tpl}"
export ovn_bridge_mappings="$OVN_BRIDGE_MAPPINGS"
export ovn_bridge_interface_mappings="$OVN_BRIDGE_INTERFACE_MAPPINGS"
envsubst '${ovn_bridge_mappings} ${ovn_bridge_interface_mappings}' \
    < "$BUNDLE_TEMPLATE_PATH" > "$BUNDLE_OUTPUT"
echo "  Rendered bundle: $BUNDLE_OUTPUT"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== Dry run: bundle rendered, skipping deployment ==="
    exit 0
fi

# --- 7. Register machines ---
echo "=== Registering machines ==="

# Get the Juju machine ID for a given IP (empty if not registered).
get_machine_id_by_ip() {
    local ip="$1"
    juju machines -m "$MODEL" --format=json 2>/dev/null \
        | jq -r --arg ip "$ip" '
            .machines
            | to_entries[]
            | select(
                ((.value."instance-id" // "") | contains($ip))
                or ((.value.hostname // "") | contains($ip))
              )
            | .key' 2>/dev/null | head -1
}

# Add a manual machine and return its Juju-assigned numeric ID.
add_machine_and_get_id() {
    local ssh_target="$1"
    local output
    output=$(juju add-machine -m "$MODEL" "ssh:$ssh_target" --private-key="$SSH_KEY_PATH" 2>&1)
    echo "$output" >&2
    echo "$output" | grep -oE 'machine [0-9]+' | tail -1 | grep -oE '[0-9]+'
}

# Register 11 control-plane VMs (idempotent — skip if already registered).
declare -A MACHINE_JUJU_IDS
for i in "${!VM_DOMAINS[@]}"; do
    domain="${VM_DOMAINS[$i]}"
    bundle_id=$((i + 1))
    ip="${VM_IPS[$domain]}"

    juju_id=$(get_machine_id_by_ip "$ip")
    if [ -n "$juju_id" ]; then
        echo "  $domain ($ip): already registered as machine $juju_id"
    else
        juju_id=$(add_machine_and_get_id "ubuntu@$ip")
        if [ -z "$juju_id" ]; then
            echo "ERROR: Failed to add machine for $domain ($ip)" >&2
            exit 1
        fi
        echo "  $domain ($ip): registered as machine $juju_id"
    fi
    MACHINE_JUJU_IDS[$bundle_id]="$juju_id"
done

# Register the hypervisor (idempotent).
echo "=== Installing public key on hypervisor ($HYPERVISOR_SSH_USER@$HYPERVISOR_IP) ==="
if ! command -v ssh-copy-id >/dev/null 2>&1; then
    echo "ERROR: ssh-copy-id not found. Install openssh-client." >&2
    exit 1
fi
ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$SSH_PUBLIC_KEY_PATH" "${HYPERVISOR_SSH_USER}@${HYPERVISOR_IP}"

hypervisor_juju_id=$(get_machine_id_by_ip "$HYPERVISOR_IP")
if [ -n "$hypervisor_juju_id" ]; then
    echo "  hypervisor ($HYPERVISOR_IP): already registered as machine $hypervisor_juju_id"
else
    hypervisor_juju_id=$(add_machine_and_get_id "${HYPERVISOR_SSH_USER}@${HYPERVISOR_IP}")
    if [ -z "$hypervisor_juju_id" ]; then
        echo "ERROR: Failed to add machine for hypervisor ($HYPERVISOR_IP)" >&2
        exit 1
    fi
    echo "  hypervisor ($HYPERVISOR_IP): registered as machine $hypervisor_juju_id"
fi

# --- 8. Deploy the bundle ---
echo "=== Deploying bundle ==="

# Build --map-machines argument. Start with "existing" (matches bundle
# machine IDs to Juju machine IDs by number), then add explicit mappings
# where the bundle ID differs from the Juju-assigned ID. The hypervisor
# always needs an explicit mapping because its bundle machine ID is the
# non-numeric string "hypervisor".
MAP_ARG="existing"
for bundle_id in 1 2 3 4 5 6 7 8 9 10 11; do
    juju_id="${MACHINE_JUJU_IDS[$bundle_id]}"
    if [ "$bundle_id" != "$juju_id" ]; then
        MAP_ARG="$MAP_ARG,$bundle_id=$juju_id"
    fi
done
MAP_ARG="$MAP_ARG,hypervisor=$hypervisor_juju_id"

echo "  Map machines: $MAP_ARG"
juju deploy -m "$MODEL" "$BUNDLE_OUTPUT" --trust --map-machines="$MAP_ARG"

echo "=== Bundle deployment initiated ==="
echo "Run 'juju status -m $MODEL' to monitor progress."
