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
# - Responsive 2.0s polling loop with instant wake-from-lid reaction
#
# Behavior:
# - Lid CLOSED: Immediately turns off backlight and drops CPU clock to minimum (setperf=0).
# - Lid OPENED: Instantly restores backlight to 100% and ramps CPU clock to maximum (setperf=100).
# - Long CLOSED (default: 2h): Optionally triggers deep power savings or hibernate.

# Configurable parameters:
# Priority: Command-line arguments > Environment variables > Defaults
POLL_INTERVAL="${POMERA_LID_INTERVAL:-2.0}"
SUSPEND_TIMEOUT="${POMERA_LID_TIMEOUT:-7200}" # 2 hours default
CPU_POLICY="${POMERA_CPU_POLICY:-auto}"
LID_STATE="open"
CLOSED_EPOCH=0

SAVED_BRIGHTNESS="${POMERA_DEFAULT_BRIGHTNESS:-100}"
BRIGHTNESS_FILE="/var/run/pomera_brightness"

while getopts "i:t:p:b:h" opt; do
    case "$opt" in
        i) POLL_INTERVAL="$OPTARG" ;;
        t) SUSPEND_TIMEOUT="$OPTARG" ;;
        p) CPU_POLICY="$OPTARG" ;;
        b) SAVED_BRIGHTNESS="$OPTARG" ;;
        h|*)
            echo "Usage: $0 [-i interval_sec] [-t timeout_sec] [-p auto|high|100] [-b default_brightness]" >&2
            exit 1
            ;;
    esac
done

# Normalize CPU policy (auto vs high/100)
case "$CPU_POLICY" in
    100|high) CPU_POLICY="high" ;;
    *) CPU_POLICY="auto" ;;
esac

# Helper to extract integer brightness percentage (e.g. "40.15%" -> "40")
get_current_brightness() {
    raw=$(wsconsctl -n display.brightness 2>/dev/null)
    # Remove % and decimal parts
    val="${raw%%%*}"
    val="${val%%.*}"
    case "$val" in
        ''|*[!0-9]*) echo "" ;;
        *) echo "$val" ;;
    esac
}

# Helper to record brightness and keep file in sync (world-writable for unprivileged tools)
save_brightness() {
    cur_b=$(get_current_brightness)
    if [ -n "$cur_b" ] && [ "$cur_b" -gt 0 ] 2>/dev/null; then
        SAVED_BRIGHTNESS="$cur_b"
        echo "$SAVED_BRIGHTNESS" > "$BRIGHTNESS_FILE" 2>/dev/null || true
        chmod 0666 "$BRIGHTNESS_FILE" 2>/dev/null || true
    fi
}

# Initialize SAVED_BRIGHTNESS from current hardware state or file
init_b=$(get_current_brightness)
if [ -n "$init_b" ] && [ "$init_b" -gt 0 ] 2>/dev/null; then
    SAVED_BRIGHTNESS="$init_b"
    save_brightness
elif [ -s "$BRIGHTNESS_FILE" ]; then
    file_b=$(cat "$BRIGHTNESS_FILE" 2>/dev/null)
    case "$file_b" in
        [1-9]|[1-9][0-9]|100) SAVED_BRIGHTNESS="$file_b" ;;
    esac
fi

# Ensure clean exit on SIGTERM/SIGINT (restore normal full power state)
cleanup() {
    wsconsctl display.brightness="${SAVED_BRIGHTNESS}%" >/dev/null 2>&1 || wsconsctl display.brightness=100 >/dev/null 2>&1 || true
    sysctl hw.perfpolicy="$CPU_POLICY" >/dev/null 2>&1 || sysctl hw.setperf=100 >/dev/null 2>&1 || true
}
trap 'cleanup; exit 0' TERM INT

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
                CLOSED_EPOCH=${SECONDS:-0}
                
                # 0. Remember current screen brightness before blanking
                save_brightness

                # 1. Turn OFF screen backlight instantly (0ms latency feel)
                wsconsctl display.brightness=0 >/dev/null 2>&1 || true
                
                # 2. Drop CPU frequency to minimum for lowest battery drain
                sysctl hw.perfpolicy=manual >/dev/null 2>&1 || true
                sysctl hw.setperf=0 >/dev/null 2>&1 || true
            else
                # Check timeout for long-term sleep (zero-fork via $SECONDS)
                elapsed=$((${SECONDS:-0} - CLOSED_EPOCH))
                if [ "$elapsed" -ge "$SUSPEND_TIMEOUT" ]; then
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
                
                # 2. Restore screen backlight to previously saved brightness level
                wsconsctl display.brightness="${SAVED_BRIGHTNESS}%" >/dev/null 2>&1 || wsconsctl display.brightness=100 >/dev/null 2>&1 || true
            fi
            # (Zero-overhead: do not query wsconsctl repeatedly while open;
            #  brightness is updated on lid close or directly by pomera-brightness)
            ;;
    esac
    
    sleep "$POLL_INTERVAL"
done
