#!/usr/bin/env bash
# =====================================================================
# run_qemu.sh - Run OpenBSD ARMv7 QEMU Simulator with USB Storage
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

WORK_DIR="${SCRIPT_DIR}/_build_cache"
DEFAULT_IMG="${WORK_DIR}/pomera_expanded.img"
if [ ! -f "$DEFAULT_IMG" ] && [ -f "${WORK_DIR}/virtual_emmc.img" ]; then
    DEFAULT_IMG="${WORK_DIR}/virtual_emmc.img"
fi
IMG_PATH="${1:-$DEFAULT_IMG}"
LOG_PATH="${WORK_DIR}/qemu_debug.log"

if ! command -v qemu-system-arm >/dev/null 2>&1; then
    echo "❌ qemu-system-arm not found on host. Install via: brew install qemu"
    exit 1
fi

if [ ! -f "$IMG_PATH" ]; then
    echo "❌ Target image not found: $IMG_PATH"
    echo "   Usage: $0 [image_path]"
    exit 1
fi

echo "=========================================================="
echo "  Starting OpenBSD ARMv7 QEMU Simulator"
echo "  Log File: ${LOG_PATH}"
echo "=========================================================="
echo "💡 To Exit QEMU: Press 'Ctrl + A' then press 'X'"
echo ""

EDK2_BIOS=""
for p in \
    /usr/share/AAVMF/AAVMF32_CODE.fd \
    /opt/homebrew/share/qemu/edk2-arm-code.fd \
    /usr/local/share/qemu/edk2-arm-code.fd \
    /opt/homebrew/Cellar/qemu/*/share/qemu/edk2-arm-code.fd \
    /usr/local/Cellar/qemu/*/share/qemu/edk2-arm-code.fd \
    /usr/share/qemu-efi-arm/QEMU_EFI.fd; do
    if compgen -G "$p" > /dev/null; then
        EDK2_BIOS=$(compgen -G "$p" | head -n 1)
        break
    fi
done

echo "=== QEMU Boot Session $(date) ===" > "$LOG_PATH"

if [ -n "$EDK2_BIOS" ] && [ -f "$EDK2_BIOS" ]; then
    echo ">> [UEFI Boot Mode] Firmware: ${EDK2_BIOS}"
    # Use USB Mass Storage device which EDK2 UEFI supports natively out of the box
    qemu-system-arm \
        -M virt \
        -cpu cortex-a7 \
        -m 1024M \
        -bios "${EDK2_BIOS}" \
        -drive if=none,file="${IMG_PATH}",format=raw,id=usbdisk \
        -device usb-ehci,id=ehci \
        -device usb-storage,bus=ehci.0,drive=usbdisk \
        -nographic 2>&1 | tee -a "$LOG_PATH"
else
    echo "❌ EDK2 BIOS not found."
    exit 1
fi
