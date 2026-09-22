#!/bin/bash
# prepare-host.sh — check and install hypervisor prerequisites for
# nova-compute with NVIDIA vGPU running directly on the host.
#
# Usage:
#   prepare-host.sh              # check prerequisites, exit non-zero on failure
#   prepare-host.sh --check      # read-only status report, always exit 0
#   prepare-host.sh --install    # install missing dependencies, then re-check
#
# This script does NOT rebind GPUs, edit GRUB, reboot, or touch the NVIDIA
# driver. The --install mode installs system packages and snaps only.
set -euo pipefail

MODE="enforce"
if [[ "${1:-}" == "--check" ]]; then
    MODE="check"
elif [[ "${1:-}" == "--install" ]]; then
    MODE="install"
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--check|--install]" >&2
    exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# report <status> <name> <detail>
report() {
    local status="$1" name="$2" detail="${3:-}"
    case "$status" in
        PASS)
            printf 'PASS  %s%s\n' "$name" "${detail:+  — $detail}"
            PASS_COUNT=$((PASS_COUNT + 1))
            ;;
        WARN)
            printf 'WARN  %s%s\n' "$name" "${detail:+  — $detail}"
            WARN_COUNT=$((WARN_COUNT + 1))
            ;;
        *)
            printf 'FAIL  %s%s\n' "$name" "${detail:+  — $detail}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac
}

# --- Dependency installation ---

install_deps() {
    echo "=== Installing host dependencies ==="
    echo

    # Ensure apt is up to date
    sudo apt-get update -qq

    # libvirt + qemu + networking tools
    local apt_pkgs=(
        libvirt-daemon-system
        libvirt-clients
        qemu-system-x86
        qemu-utils
        bridge-utils
        dnsmasq-base
        ebtables
        iproute2
        jq
        curl
    )

    local missing_pkgs=()
    for pkg in "${apt_pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo "Installing apt packages: ${missing_pkgs[*]}"
        sudo apt-get install -y -qq "${missing_pkgs[@]}"
    else
        echo "All apt packages already installed."
    fi

    # Enable and start libvirtd
    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        echo "Enabling and starting libvirtd..."
        sudo systemctl enable --now libvirtd
    fi

    # Ensure the current user is in the libvirt group (so virsh works
    # without sudo against qemu:///system)
    if ! id -nG | grep -qw libvirt; then
        echo "Adding user $(whoami) to the libvirt group..."
        sudo usermod -aG libvirt "$(whoami)"
        echo "  Note: you may need to log out and back in (or run 'newgrp libvirt') for this to take effect."
    fi

    # Juju via snap
    if ! command -v juju >/dev/null 2>&1; then
        echo "Installing Juju via snap..."
        sudo snap install juju --classic
    else
        echo "Juju already installed: $(command -v juju)"
    fi

    # Vault CLI via snap
    if ! command -v vault >/dev/null 2>&1; then
        echo "Installing Vault CLI via snap..."
        sudo snap install vault
    else
        echo "Vault CLI already installed: $(command -v vault)"
    fi

    # Terraform via snap
    if ! command -v terraform >/dev/null 2>&1; then
        echo "Installing Terraform via snap..."
        sudo snap install terraform --classic
    else
        echo "Terraform already installed: $(command -v terraform)"
    fi

    echo
    echo "=== Dependency installation complete ==="
    echo
}

# --- Prerequisite checks ---

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

# 5. Vault CLI installed.
check_vault() {
    if command -v vault >/dev/null 2>&1; then
        report PASS "Vault CLI installed" "$(command -v vault)"
    else
        report FAIL "Vault CLI installed" "vault not found in PATH (run: snap install vault)"
    fi
}

# 6. Terraform installed.
check_terraform() {
    if command -v terraform >/dev/null 2>&1; then
        local ver
        ver="$(terraform version 2>/dev/null | head -1)"
        report PASS "Terraform installed" "$ver"
    else
        report FAIL "Terraform installed" "terraform not found in PATH (>= 1.7 required)"
    fi
}

# 7. jq installed.
check_jq() {
    if command -v jq >/dev/null 2>&1; then
        report PASS "jq installed" "$(command -v jq)"
    else
        report FAIL "jq installed" "jq not found in PATH (run: apt install jq)"
    fi
}

# 8. NVIDIA vGPU driver loaded (nvidia_vgpu_vfio or nvidia module).
check_nvidia_driver() {
    if lsmod 2>/dev/null | grep -Eq 'nvidia_vgpu_vfio|nvidia'; then
        local mod
        mod="$(lsmod 2>/dev/null | awk '/^(nvidia_vgpu_vfio|nvidia)/ {print $1; exit}')"
        report PASS "NVIDIA vGPU driver loaded" "module ${mod:-nvidia*} loaded"
    else
        report WARN "NVIDIA vGPU driver loaded" "neither nvidia_vgpu_vfio nor nvidia in lsmod (the driver may not be installed yet)"
    fi
}

# 9. sriov-manage tool available at the NVIDIA vGPU software path.
check_sriov_manage() {
    if [[ -f /usr/lib/nvidia/sriov-manage ]]; then
        report PASS "sriov-manage available" "/usr/lib/nvidia/sriov-manage"
    else
        report WARN "sriov-manage available" "/usr/lib/nvidia/sriov-manage not found (install the NVIDIA vGPU software package)"
    fi
}

# --- Main ---

# In install mode, install dependencies first, then run checks
if [[ "$MODE" == "install" ]]; then
    install_deps
fi

echo "Host prerequisite checks (mode: $MODE)"
echo

check_iommu
check_nvidia_gpu
check_libvirtd
check_juju
check_vault
check_terraform
check_jq
check_nvidia_driver
check_sriov_manage

echo
echo "Summary: ${PASS_COUNT} passed, ${WARN_COUNT} warnings, ${FAIL_COUNT} failed"

if [[ "$MODE" == "check" ]]; then
    exit 0
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
