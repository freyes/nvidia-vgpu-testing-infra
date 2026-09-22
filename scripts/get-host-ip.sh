#!/bin/bash
# get-host-ip.sh — print candidate management IPv4 addresses and a best guess.
#
# Usage:
#   get-host-ip.sh             # list candidates + best guess (human readable)
#   get-host-ip.sh --best-only # print only the best-guess IP (or empty string)
#   get-host-ip.sh --json      # emit JSON via jq
#
# Excludes virtual/bridge/container interfaces and link-local/loopback
# addresses. The best guess prefers the interface that carries the default
# route, falling back to the first candidate.
#
# This script only prints; it does NOT write to any Terraform state.
set -euo pipefail

MODE="default"
for arg in "$@"; do
    case "$arg" in
        --best-only) MODE="best-only" ;;
        --json)      MODE="json" ;;
        *) echo "usage: $0 [--best-only|--json]" >&2; exit 2 ;;
    esac
done

# Interfaces to ignore: loopback plus virtual/bridge/container links.
EXCLUDE_IF_RE='^(lo|virbr.*|docker.*|lxdbr.*|br-.*|veth.*|tap.*|vnet.*|podman.*)$'

# Collect candidate (interface, address) pairs from global IPv4 addresses.
declare -a IFACES=() ADDRS=()
while read -r iface addr_cidr; do
    [[ -z "$iface" ]] && continue
    if [[ "$iface" =~ $EXCLUDE_IF_RE ]]; then
        continue
    fi
    addr="${addr_cidr%%/*}"
    # Skip link-local (169.254.*) and loopback (127.*).
    if [[ "$addr" =~ ^169\.254\. ]] || [[ "$addr" =~ ^127\. ]]; then
        continue
    fi
    IFACES+=("$iface")
    ADDRS+=("$addr")
done < <(ip -4 -o addr show scope global | awk '{ print $2, $4 }')

# Default-route interface (may be empty if there is no default route).
DEFAULT_IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ print $5; exit }' || true)"

# Best guess: prefer the candidate on the default-route interface, else the
# first candidate. Empty when there are no candidates.
BEST=""
BEST_IFACE=""
BEST_REASON=""
if [[ ${#IFACES[@]} -gt 0 ]]; then
    best_idx=-1
    if [[ -n "$DEFAULT_IFACE" ]]; then
        for i in "${!IFACES[@]}"; do
            if [[ "${IFACES[$i]}" == "$DEFAULT_IFACE" ]]; then
                best_idx=$i
                break
            fi
        done
    fi
    if [[ $best_idx -ge 0 ]]; then
        BEST="${ADDRS[$best_idx]}"
        BEST_IFACE="${IFACES[$best_idx]}"
        BEST_REASON="interface ${IFACES[$best_idx]} carries the default route"
    else
        BEST="${ADDRS[0]}"
        BEST_IFACE="${IFACES[0]}"
        if [[ -n "$DEFAULT_IFACE" ]]; then
            BEST_REASON="default route on ${DEFAULT_IFACE} has no global IPv4 candidate; using first candidate"
        else
            BEST_REASON="no default route; first global IPv4"
        fi
    fi
fi

emit_default() {
    echo "Candidate management IPv4 addresses:"
    if [[ ${#IFACES[@]} -eq 0 ]]; then
        echo "  (none)"
    else
        for i in "${!IFACES[@]}"; do
            tag=""
            if [[ -n "$DEFAULT_IFACE" && "${IFACES[$i]}" == "$DEFAULT_IFACE" ]]; then
                tag=" (default route)"
            fi
            printf '  - %s  on %s%s\n' "${ADDRS[$i]}" "${IFACES[$i]}" "$tag"
        done
    fi
    echo
    if [[ -n "$BEST" ]]; then
        printf 'Best guess: %s  (%s)\n' "$BEST" "$BEST_REASON"
    else
        echo "Best guess: (none)"
    fi
}

emit_best_only() {
    printf '%s\n' "$BEST"
}

emit_json() {
    local cands_json
    cands_json="$(
        {
            for i in "${!IFACES[@]}"; do
                printf '%s\t%s\n' "${IFACES[$i]}" "${ADDRS[$i]}"
            done
        } | jq -Rn '[inputs | split("\t") | {interface: .[0], address: .[1]}]'
    )"
    jq -n \
        --arg best "$BEST" \
        --arg drif "$DEFAULT_IFACE" \
        --argjson cands "$cands_json" \
        '{best_guess: $best, default_route_interface: $drif, candidates: $cands}'
}

case "$MODE" in
    default)   emit_default ;;
    best-only) emit_best_only ;;
    json)      emit_json ;;
esac
