#!/bin/sh
# /usr/local/sbin/pomera-wifi-watch
# Pomera DM250 Wi-Fi Health Monitor & Auto-Reconnect Daemon for OpenBSD
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Modes:
# 1. Manual Reconnect (Single-shot):
#    Run as 'pomera-wifi-reconnect' or 'pomera-wifi-watch -r' to immediately
#    cycle the bwfm0 interface and reacquire a DHCP lease.
#
# 2. Daemon Mode (Background Service):
#    Run as 'pomera-wifi-watch' (default when started via rcctl).
#    Monitors Wi-Fi link status every 10s and automatically reconnects
#    when the link drops, with safety delay on sleep resume.

INTERFACE="bwfm0"
POLL_INTERVAL=10
DOWN_RETRY_TIMEOUT=15
RESUME_THRESHOLD=20
RESUME_SETTLE=5

reconnect_wifi() {
    echo ">> [pomera-wifi] Cycling ${INTERFACE} interface..."
    ifconfig "${INTERFACE}" down 2>/dev/null || true
    sleep 1
    ifconfig "${INTERFACE}" up 2>/dev/null || true

    echo ">> [pomera-wifi] Requesting DHCP lease on ${INTERFACE}..."
    pkill -f "dhclient.*${INTERFACE}" 2>/dev/null || true
    if [ -f /etc/hostname."${INTERFACE}" ]; then
        sh /etc/netstart "${INTERFACE}" >/dev/null 2>&1 || dhclient "${INTERFACE}"
    else
        dhclient "${INTERFACE}"
    fi

    # Check result
    if ifconfig "${INTERFACE}" 2>/dev/null | grep -q "status: active"; then
        echo "✅ [pomera-wifi] ${INTERFACE} connected successfully."
        return 0
    else
        echo "⚠️ [pomera-wifi] ${INTERFACE} link not active yet."
        return 1
    fi
}

# If invoked as 'pomera-wifi-reconnect' or with '-r', run single-shot manual reconnect
BASENAME="$(basename "$0")"
if [ "$BASENAME" = "pomera-wifi-reconnect" ] || [ "$1" = "-r" ] || [ "$1" = "--reconnect" ]; then
    reconnect_wifi
    exit $?
fi

# Daemon Mode
echo ">> Starting pomera-wifi-watch daemon on ${INTERFACE} (interval: ${POLL_INTERVAL}s)..."

down_since=0

while true; do
    t0=$(date +%s)
    sleep "$POLL_INTERVAL"
    t1=$(date +%s)
    elapsed=$((t1 - t0))

    # Detect wake-from-sleep: if sleep took longer than expected, settle before touching Wi-Fi
    if [ "$elapsed" -gt "$RESUME_THRESHOLD" ]; then
        echo ">> [pomera-wifi] System resume detected (slept ${elapsed}s). Settling ${RESUME_SETTLE}s..."
        sleep "$RESUME_SETTLE"
        down_since=0
    fi

    # Check if interface exists
    if ! ifconfig "${INTERFACE}" >/dev/null 2>&1; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Check Wi-Fi link status
    if ifconfig "${INTERFACE}" 2>/dev/null | grep -q "status: active"; then
        down_since=0
    else
        if [ "$down_since" -eq 0 ]; then
            down_since=$t1
            echo ">> [pomera-wifi] Link is down. Monitoring (retry timeout: ${DOWN_RETRY_TIMEOUT}s)..."
        elif [ $((t1 - down_since)) -ge "$DOWN_RETRY_TIMEOUT" ]; then
            echo ">> [pomera-wifi] Link has been down for $((t1 - down_since))s. Attempting auto-reconnect..."
            reconnect_wifi
            down_since=$t1
        fi
    fi
done
