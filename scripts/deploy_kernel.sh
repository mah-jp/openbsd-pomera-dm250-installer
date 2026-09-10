#!/usr/bin/env bash
# =====================================================================
# deploy_kernel.sh - Deploy Patched Kernel to Pomera DM250
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
KERNEL_SRC="${REPO_ROOT}/_build_cache/bsd.patched"

if [ ! -f "$KERNEL_SRC" ]; then
    echo "❌ Error: Patched kernel not found at:"
    echo "   ${KERNEL_SRC}"
    echo "Run scripts/build_kernel_qemu.py first to compile it."
    exit 1
fi

echo "=========================================================="
echo "🚀 Pomera DM250 Patched Kernel Deployment Helper"
echo "=========================================================="
echo "Source Kernel: ${KERNEL_SRC} ($(ls -lh "$KERNEL_SRC" | awk '{print $5}'))"
echo ""
if [ $# -ge 1 ]; then
    CHOICE=1
    POMERA_HOST="$1"
    POMERA_USER="${2:-pomera}"
else
    echo "Select deployment method:"
    echo "  1) Wi-Fi / SSH (Over the Air - Instant)"
    echo "  2) Copy to Mounted SD Card (Physical)"
    echo "  3) Show Manual Installation Commands"
    echo ""
    read -r -p "Enter choice [1]: " CHOICE
    CHOICE="${CHOICE:-1}"
fi

case "$CHOICE" in
    1)
        if [ $# -lt 1 ]; then
            read -r -p "Enter Pomera IP or Hostname [pomera.local]: " POMERA_HOST
            POMERA_HOST="${POMERA_HOST:-pomera.local}"
            read -r -p "Enter SSH Username [pomera]: " POMERA_USER
            POMERA_USER="${POMERA_USER:-pomera}"
        fi

        echo ""
        echo ">> Uploading bsd.patched to ${POMERA_USER}@${POMERA_HOST}..."
        scp "$KERNEL_SRC" "${POMERA_USER}@${POMERA_HOST}:/tmp/bsd.patched"

        echo ">> Applying patched kernel to /bsd (backing up existing kernel to /bsd.orig)..."
        ssh -t "${POMERA_USER}@${POMERA_HOST}" "
            doas cp /bsd /bsd.orig && \
            doas cp /tmp/bsd.patched /bsd && \
            rm -f /tmp/bsd.patched && \
            echo '✅ Patched kernel deployed successfully! Rebooting now...' && \
            doas reboot
        "
        ;;
    2)
        echo "Available mounted volumes:"
        df -h | grep -E "/Volumes|/media|/mnt" || true
        echo ""
        read -r -p "Enter path to SD card mount point (e.g. /Volumes/POMERA): " SD_PATH
        if [ ! -d "$SD_PATH" ]; then
            echo "❌ Path not found: $SD_PATH"
            exit 1
        fi
        echo ">> Copying to ${SD_PATH}/bsd..."
        cp -v "$KERNEL_SRC" "${SD_PATH}/bsd"
        sync
        echo "✅ Kernel copied to SD card. Boot Pomera from SD card or copy to eMMC."
        ;;
    3|*)
        echo ""
        echo "=== Manual Deployment Instructions ==="
        echo "1. Copy ${KERNEL_SRC} to Pomera via USB drive, SD card, or SCP:"
        echo "   scp ${KERNEL_SRC} pomera@<pomera-ip>:/tmp/bsd.patched"
        echo ""
        echo "2. On Pomera terminal:"
        echo "   doas cp /bsd /bsd.orig"
        echo "   doas cp /tmp/bsd.patched /bsd"
        echo "   doas reboot"
        echo "======================================="
        ;;
esac
