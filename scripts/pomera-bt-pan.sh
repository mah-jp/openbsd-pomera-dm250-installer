#!/bin/sh
# pomera-bt-pan.sh - Bluetooth PAN (Personal Area Network) Tethering Tool for Pomera DM250
#
# Inspired by panctl research and tooling by 4noha (MIT License)
# https://github.com/4noha/openbsd-pomera-dm250
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Connects to smartphone Bluetooth Tethering (PAN) on OpenBSD.
# Usage:
#   doas /usr/local/bin/pomera-bt-pan [connect <BD_ADDR> | disconnect | status]

ACTION="${1:-status}"
TARGET_BDADDR="${2:-}"

# Check for bcmbt or btconfig
check_bt() {
    if ! ifconfig tap0 >/dev/null 2>&1; then
        echo "Creating tap0 interface..."
        ifconfig tap0 create 2>/dev/null || true
    fi
}

connect_pan() {
    if [ -z "$TARGET_BDADDR" ]; then
        echo "Error: Bluetooth BD_ADDR required (e.g. 12:34:56:78:9A:BC)"
        echo "Usage: $0 connect <BD_ADDR>"
        exit 1
    fi
    
    echo ">> Connecting to Bluetooth PAN device: $TARGET_BDADDR..."
    # panctl connect
    if command -v panctl >/dev/null 2>&1; then
        panctl connect "$TARGET_BDADDR"
        echo ">> Requesting DHCP on Bluetooth tap0..."
        dhclient tap0
        echo "✅ Connected to Bluetooth Tethering!"
    else
        echo "⚠️ panctl not found. Please build and install panctl from: https://github.com/4noha/openbsd-pomera-dm250"
        exit 1
    fi
}

disconnect_pan() {
    echo ">> Disconnecting Bluetooth PAN..."
    if command -v panctl >/dev/null 2>&1; then
        panctl disconnect || true
    fi
    pkill -f "dhclient.*tap0" 2>/dev/null || true
    ifconfig tap0 down 2>/dev/null || true
    echo "✅ Disconnected."
}

show_status() {
    if ifconfig tap0 2>/dev/null | grep -q "inet"; then
        echo "Bluetooth PAN: Connected"
        ifconfig tap0 | grep "inet"
    else
        echo "Bluetooth PAN: Disconnected"
    fi
}

case "$ACTION" in
    connect)
        check_bt
        connect_pan
        ;;
    disconnect)
        disconnect_pan
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [connect <BD_ADDR> | disconnect | status]"
        exit 1
        ;;
esac
