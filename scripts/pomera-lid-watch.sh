#!/bin/sh
# /etc/pomera-lid-watch.sh (or /usr/local/sbin/pomera-lid-watch)
# Pomera DM250 Ultra-Fast Lid Power Management Daemon for OpenBSD
#
# Based on harness/pomera-lid-watch.sh by 4noha (MIT License)
# https://github.com/4noha/openbsd-pomera-dm250
# Copyright (c) 2026 4noha
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Enhancements:
# - Dynamic CPU setperf scaling (setperf=0 on close, setperf=100 on open)
# - Ultra-fast 0.5s polling loop for instantaneous resume feel
#
# Behavior:
# - Lid CLOSED: Immediately turns off backlight and drops CPU clock to minimum (setperf=0).
# - Lid OPENED: Instantly restores backlight to 100% and ramps CPU clock to maximum (setperf=100).
# - Long CLOSED (default: 2h): Optionally triggers deep power savings or hibernate.

# Configurable parameters:
# Priority: Command-line arguments > Environment variables > Defaults
POLL_INTERVAL="${POMERA_LID_INTERVAL:-0.5}"
SUSPEND_TIMEOUT="${POMERA_LID_TIMEOUT:-7200}" # 2 hours default
CPU_POLICY="${POMERA_CPU_POLICY:-auto}"
LID_STATE="open"
CLOSED_EPOCH=0

while getopts "i:t:p:h" opt; do
    case "$opt" in
        i) POLL_INTERVAL="$OPTARG" ;;
        t) SUSPEND_TIMEOUT="$OPTARG" ;;
        p) CPU_POLICY="$OPTARG" ;;
        h|*)
            echo "Usage: $0 [-i interval_sec] [-t timeout_sec] [-p auto|high|100]" >&2
            exit 1
            ;;
    esac
done

# Normalize CPU policy (auto vs high/100)
case "$CPU_POLICY" in
    100|high) CPU_POLICY="high" ;;
    *) CPU_POLICY="auto" ;;
esac

# Ensure clean exit on SIGTERM/SIGINT (restore normal full power state)
trap 'wsconsctl display.brightness=100 >/dev/null 2>&1 || true; sysctl hw.perfpolicy="'"$CPU_POLICY"'" >/dev/null 2>&1 || sysctl hw.setperf=100 >/dev/null 2>&1 || true; exit 0' TERM INT

# Ensure sensor is available
check_lid() {
    # Check via hw.sensors (gpiokeys lid switch)
    sysctl -n hw.sensors.gpiokeys0.indicator0 2>/dev/null || echo "Unknown"
}

# Main loop
while true; do
    raw_state=$(check_lid)
    
    case "$raw_state" in
        Off*|*closed*)
            # Lid is CLOSED
            if [ "$LID_STATE" != "closed" ]; then
                LID_STATE="closed"
                CLOSED_EPOCH=$(date +%s)
                
                # 1. Turn OFF screen backlight instantly (0ms latency feel)
                wsconsctl display.brightness=0 >/dev/null 2>&1 || true
                
                # 2. Drop CPU frequency to minimum for lowest battery drain
                sysctl hw.perfpolicy=manual >/dev/null 2>&1 || true
                sysctl hw.setperf=0 >/dev/null 2>&1 || true
            else
                # Check timeout for long-term sleep
                now=$(date +%s)
                elapsed=$((now - CLOSED_EPOCH))
                if [ $elapsed -ge $SUSPEND_TIMEOUT ]; then
                    if [ -x /usr/local/sbin/pomera-suspend ]; then
                        /usr/local/sbin/pomera-suspend
                    elif [ -x /etc/pomera-suspend ]; then
                        /etc/pomera-suspend
                    fi
                fi
            fi
            ;;
        *)
            # Lid is OPEN (or Unknown)
            if [ "$LID_STATE" != "open" ]; then
                LID_STATE="open"
                CLOSED_EPOCH=0
                
                # 1. Restore CPU frequency to configured policy (auto scaling or high performance)
                sysctl hw.perfpolicy="$CPU_POLICY" >/dev/null 2>&1 || sysctl hw.setperf=100 >/dev/null 2>&1 || true
                
                # 2. Turn ON screen backlight instantly
                wsconsctl display.brightness=100 >/dev/null 2>&1 || true
            fi
            ;;
    esac
    
    sleep "$POLL_INTERVAL"
done
