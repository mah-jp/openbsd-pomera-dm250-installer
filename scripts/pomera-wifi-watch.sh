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
POLL_INTERVAL=15
DOWN_RETRY_TIMEOUT=15
RESUME_THRESHOLD=25
RESUME_SETTLE=8
PAUSE_FILE="/var/run/pomera_wifi_pause"
LOCK_DIR="/var/run/pomera_wifi_reconnect.lock"

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    # Check staleness: if lock directory is older than 60s, force-clean
    if [ -d "$LOCK_DIR" ]; then
        stale=$(find "$LOCK_DIR" -prune -mmin +1 2>/dev/null || true)
        if [ -n "$stale" ]; then
            rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null || true
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                return 0
            fi
        fi
    fi
    return 1
}

release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null || true
}

reconnect_wifi() {
    if ! acquire_lock; then
        logger -t pomera-wifi "Another Wi-Fi reconnect operation is already running. Skipping." 2>/dev/null || true
        return 0
    fi

    # Ensure lock cleanup on exit/signals
    trap 'release_lock' EXIT INT TERM

    logger -t pomera-wifi "Cycling ${INTERFACE} interface..." 2>/dev/null || true
    ifconfig "${INTERFACE}" down 2>/dev/null || true
    sleep 1
    ifconfig "${INTERFACE}" up 2>/dev/null || true

    logger -t pomera-wifi "Requesting DHCP lease on ${INTERFACE}..." 2>/dev/null || true
    pkill -f "dhclient.*${INTERFACE}" 2>/dev/null || true
    if [ -f /etc/hostname."${INTERFACE}" ]; then
        sh /etc/netstart "${INTERFACE}" >/dev/null 2>&1 || dhclient "${INTERFACE}"
    else
        dhclient "${INTERFACE}"
    fi

    # Check result
    rc=1
    if ifconfig "${INTERFACE}" 2>/dev/null | grep -q "status: active"; then
        logger -t pomera-wifi "${INTERFACE} connected successfully." 2>/dev/null || true
        rc=0
    else
        logger -t pomera-wifi "${INTERFACE} link not active yet." 2>/dev/null || true
        rc=1
    fi

    release_lock
    trap - EXIT INT TERM
    return $rc
}

# If invoked as 'pomera-wifi-reconnect' or with '-r', run single-shot manual reconnect
BASENAME="$(basename "$0")"
if [ "$BASENAME" = "pomera-wifi-reconnect" ] || [ "${1:-}" = "-r" ] || [ "${1:-}" = "--reconnect" ]; then
    reconnect_wifi
    exit $?
fi

# Daemon Mode
down_since=0

while true; do
    t0=${SECONDS:-0}
    sleep "$POLL_INTERVAL"
    t1=${SECONDS:-0}
    elapsed=$((t1 - t0))

    # If Wi-Fi is temporarily paused by pomera-lid-watch (during suspend or low-power state), do nothing
    if [ -f "$PAUSE_FILE" ]; then
        down_since=0
        continue
    fi

    # Detect wake-from-sleep: if sleep took longer than expected, settle before touching Wi-Fi
    if [ "$elapsed" -gt "$RESUME_THRESHOLD" ]; then
        sleep "$RESUME_SETTLE"
        down_since=0
    fi

    # Fast single-call link check (combines existence & status into 1 command)
    if ifconfig "${INTERFACE}" 2>/dev/null | grep -q "status: active"; then
        down_since=0
    else
        if [ "$down_since" -eq 0 ]; then
            down_since=$t1
        elif [ $((t1 - down_since)) -ge "$DOWN_RETRY_TIMEOUT" ]; then
            reconnect_wifi
            down_since=$t1
        fi
    fi
done
