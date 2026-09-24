#!/bin/bash
# vault-unseal-and-authorise.sh — initialize, unseal, and authorize-charm
# for the Vault charm in the deployed OpenStack bundle.
#
# Adapted from stsstack-bundles tools/vault-unseal-and-authorise.sh.
# Self-contained: does NOT source juju_helpers or any external helpers.
#
# Environment variables:
#   JUJU_MODEL              Juju workload model name (default: openstack)
#   JUJU_CONTROLLER_NAME    Juju controller name (default: vgpu-controller)
set -euo pipefail
set -x

# --- 1. Read environment variables ---
JUJU_MODEL="${JUJU_MODEL:-openstack}"
JUJU_CONTROLLER_NAME="${JUJU_CONTROLLER_NAME:-vgpu-controller}"
MODEL="${JUJU_CONTROLLER_NAME}:${JUJU_MODEL}"

# --- 2. Install dependencies if missing ---
command -v vault > /dev/null 2>&1 || sudo snap install vault > /dev/null 2>&1
command -v jq > /dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y jq; } > /dev/null 2>&1

# --- 3. Get model name and UUID ---
model=$(juju show-model --format=json | jq -r '. | keys[]')
model_uuid=$(juju show-model --format=json | jq -r '.[]."model-uuid"')

# --- 4. Define unseal output path and protect it ---
umask 077
unseal_output="${HOME}/unseal_output.${model}"

# --- 5. Wait for vault application to appear, then get addresses ---
ftmp=$(mktemp --tmpdir=$(pwd))
trap 'rm -f "$ftmp"' EXIT

echo "Waiting for vault application to be ready..."
leader=""
leader_addr=""
addrs=()
for attempt in $(seq 1 60); do
    juju status -m "$MODEL" --format=json vault > "$ftmp" 2>/dev/null || true
    leader="$(jq -r '.applications[] | select(."charm-name"=="vault") | .units | to_entries[] | select(.value.leader==true) | .key' "$ftmp" 2>/dev/null)"
    leader_addr="$(jq -r '.applications[]| select(."charm-name"=="vault") |.units | to_entries[] | select(.value.leader==true) | .value."public-address"' "$ftmp" 2>/dev/null)"
    if [[ -n "$leader" ]] && [[ -n "$leader_addr" ]]; then
        readarray -t addrs < <(jq -r '.applications[].units[]?."public-address" | select(. != null)' "$ftmp" 2>/dev/null)
        echo "  Vault leader found: $leader ($leader_addr)"
        break
    fi
    echo "  Waiting for vault (attempt ${attempt}/60)..."
    sleep 10
done

if [[ -z "$leader" ]] || [[ -z "$leader_addr" ]]; then
    echo "ERROR: vault leader not found after 60 attempts" >&2
    exit 1
fi
if [ ${#addrs[@]} -eq 0 ]; then
    echo "ERROR: No vault unit addresses found" >&2
    exit 1
fi

echo "=== Vault unseal and authorize-charm ==="
echo "  Model:   $MODEL"
echo "  Leader:  $leader ($leader_addr)"
echo "  Units:   ${addrs[*]}"

# --- 6. Wait for vault API to be reachable, then check status ---
export VAULT_ADDR="http://${leader_addr}:8200"
echo "Waiting for vault API at ${VAULT_ADDR}..."
for attempt in $(seq 1 60); do
    set +e
    vault status > /dev/null 2>&1
    leader_status_rc=$?
    set -e
    if [ "$leader_status_rc" -eq 0 ] || [ "$leader_status_rc" -eq 1 ] || [ "$leader_status_rc" -eq 2 ]; then
        echo "  Vault API is responding (status rc=$leader_status_rc)."
        break
    fi
    echo "  Waiting for vault API (attempt ${attempt}/60)..."
    sleep 10
done

if [ "$leader_status_rc" -ne 0 ] && [ "$leader_status_rc" -ne 1 ] && [ "$leader_status_rc" -ne 2 ]; then
    echo "ERROR: vault API not reachable after 60 attempts (rc=$leader_status_rc)" >&2
    exit 1
fi

# vault status exit codes: 0 = unsealed, 1 = sealed, 2 = uninitialized

if [ "$leader_status_rc" -eq 2 ]; then
    echo "  Vault is not initialized. Initializing..."
    echo "$model_uuid" > "$unseal_output"
    chmod 600 "$unseal_output"
    vault operator init -key-shares=5 -key-threshold=3 >> "$unseal_output" 2>&1
    echo "  Vault initialized. Unseal output saved to: $unseal_output"
elif [ "$leader_status_rc" -eq 0 ]; then
    echo "  Vault leader is already initialized and unsealed."
elif [ "$leader_status_rc" -eq 1 ]; then
    echo "  Vault leader is initialized but sealed. Will unseal."
else
    echo "ERROR: vault status returned unexpected exit code $leader_status_rc" >&2
    exit 1
fi

# --- 7. Extract unseal keys and root token from the unseal output ---
key1=$(sed -r 's/Unseal Key 1: (.+)/\1/g;t;d' "$unseal_output")
key2=$(sed -r 's/Unseal Key 2: (.+)/\1/g;t;d' "$unseal_output")
key3=$(sed -r 's/Unseal Key 3: (.+)/\1/g;t;d' "$unseal_output")
token=$(sed -r 's/Initial Root Token: (.+)/\1/g;t;d' "$unseal_output")

# --- 8. Unseal all vault units (skip those already unsealed) ---
for addr in "${addrs[@]}"; do
    export VAULT_ADDR="http://${addr}:8200"
    set +e
    vault status > /dev/null 2>&1
    unit_status_rc=$?
    set -e
    if [ "$unit_status_rc" -eq 0 ]; then
        echo "  $addr: already unsealed, skipping."
    elif [ "$unit_status_rc" -eq 1 ]; then
        echo "  $addr: unsealing..."
        vault operator unseal "$key1"
        vault operator unseal "$key2"
        vault operator unseal "$key3"
    else
        echo "ERROR: vault at $addr is not initialized (rc=$unit_status_rc)" >&2
        exit 1
    fi
done

# --- 9. Authorize the charm ---
export VAULT_TOKEN="$token"
echo "  Authorizing vault charm..."
juju run -m "$MODEL" vault/leader authorize-charm token="$token" 2>&1

# --- 10. Summary ---
echo "=== Vault initialization complete ==="
echo "  Model:            $MODEL"
echo "  Leader:           $leader ($leader_addr)"
echo "  Unseal output:    $unseal_output"
echo "  Charm authorized: yes"
