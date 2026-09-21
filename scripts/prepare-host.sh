#!/bin/bash
# prepare-host.sh — check hypervisor prerequisites for nova-compute with
# NVIDIA vGPU running directly on the host.
#
# Usage:
#   prepare-host.sh           # check prerequisites, exit non-zero on failure
#   prepare-host.sh --check   # read-only status report, always exit 0
#
# This script does NOT mutate the host: it does not rebind GPUs, edit GRUB,
# reboot, or install packages. It only reports the state of prerequisites.
set -euo pipefail

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

# report <status> <name> <detail>
report() {
    local status="$1" name="$2" detail="${3:-}"
    if [[ "$status" == "PASS" ]]; then
        printf 'PASS  %s%s\n' "$name" "${detail:+  — $detail}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf 'FAIL  %s%s\n' "$name" "${detail:+  — $detail}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# 1. IOMMU enabled in kernel command line AND IOMMU groups present.
check_iommu() {
    local detail=""
    if grep -q 'intel_iommu=on' /proc/cmdline 2>/dev/null \
        || grep -q 'amd_iommu=on' /proc/cmdline 2>/dev/null; then
        if [[ -d /sys/kernel/iommu_groups ]] \
            && [[ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
            report PASS "IOMMU support" "iommu=on in /proc/cmdline and IOMMU groups present"
            return
        fi
        detail="iommu=on in /proc/cmdline but /sys/kernel/iommu_groups is empty"
    else
        detail="neither intel_iommu=on nor amd_iommu=on in /proc/cmdline"
    fi
    report FAIL "IOMMU support" "$detail"
}

# 2. NVIDIA GPU present (PCI vendor 0x10de or lspci match).
check_nvidia_gpu() {
    local detail=""
    if command -v lspci >/dev/null 2>&1 \
        && lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
        report PASS "NVIDIA GPU present" "lspci reports an NVIDIA device"
        return
    fi
    local dev vendor
    for dev in /sys/bus/pci/devices/*/vendor; do
        [[ -r "$dev" ]] || continue
        vendor="$(<"$dev")"
        if [[ "$vendor" == "0x10de" ]]; then
            report PASS "NVIDIA GPU present" "PCI vendor 0x10de at ${dev%/vendor}"
            return
        fi
    done
    report FAIL "NVIDIA GPU present" "no NVIDIA PCI device found via lspci or /sys/bus/pci/devices"
}

# 3. libvirtd service active.
check_libvirtd() {
    if systemctl is-active --quiet libvirtd 2>/dev/null; then
        report PASS "libvirtd running" "service is active"
    else
        report FAIL "libvirtd running" "libvirtd is not active (systemctl is-active libvirtd)"
    fi
}

# 4. Juju CLI installed.
check_juju() {
    if command -v juju >/dev/null 2>&1; then
        report PASS "Juju installed" "$(command -v juju)"
    else
        report FAIL "Juju installed" "juju not found in PATH"
    fi
}

# 5. NVIDIA vGPU driver loaded (nvidia_vgpu_vfio or nvidia module).
check_nvidia_driver() {
    if lsmod 2>/dev/null | grep -Eq 'nvidia_vgpu_vfio|nvidia'; then
        local mod
        mod="$(lsmod 2>/dev/null | awk '/^(nvidia_vgpu_vfio|nvidia)/ {print $1; exit}')"
        report PASS "NVIDIA vGPU driver loaded" "module ${mod:-nvidia*} loaded"
    else
        report FAIL "NVIDIA vGPU driver loaded" "neither nvidia_vgpu_vfio nor nvidia in lsmod"
    fi
}

# 6. sriov-manage tool available at the NVIDIA vGPU software path.
check_sriov_manage() {
    if [[ -f /usr/lib/nvidia/sriov-manage ]]; then
        report PASS "sriov-manage available" "/usr/lib/nvidia/sriov-manage"
    else
        report FAIL "sriov-manage available" "/usr/lib/nvidia/sriov-manage not found"
    fi
}

echo "Host prerequisite checks (mode: $([[ $CHECK_ONLY -eq 1 ]] && echo 'check' || echo 'enforce'))"
echo

check_iommu
check_nvidia_gpu
check_libvirtd
check_juju
check_nvidia_driver
check_sriov_manage

echo
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [[ $CHECK_ONLY -eq 1 ]]; then
    exit 0
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0