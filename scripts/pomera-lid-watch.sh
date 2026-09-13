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
# - Lid CLOSED: Immediately turns off backlight and drops CPU clock to minimum (setperf=0 / 216MHz).
#               Maintains rock-solid stability indefinitely without entering risky deep suspend.
# - Lid OPENED: Instantly restores backlight to saved level and restores CPU clock policy (auto/100).
# - Long CLOSED: Safe low-clock/screen-off state is maintained indefinitely (timeout disabled by default).

# Configurable parameters:
# Priority: Command-line arguments > Environment variables > Defaults
parse_duration() {
    _val="$1"
    case "$_val" in
        *h|*H)
            _num="${_val%[hH]}"
            echo $(( ${_num:-0} * 3600 ))
            ;;
        *m|*M)
            _num="${_val%[mM]}"
            echo $(( ${_num:-0} * 60 ))
            ;;
        *s|*S)
            _num="${_val%[sS]}"
            echo $(( ${_num:-0} ))
            ;;
        ''|*[!0-9]*)
            echo 0
            ;;
        *)
            echo "$_val"
            ;;
    esac
}

POLL_INTERVAL="${POMERA_LID_INTERVAL:-2.0}"
RAW_TIMEOUT="${POMERA_LID_TIMEOUT:-0}"
SUSPEND_TIMEOUT=$(parse_duration "$RAW_TIMEOUT") # Default: 0 (disabled: stay in low-clock mode safely)
CPU_POLICY="${POMERA_CPU_POLICY:-auto}"
LID_STATE="open"
CLOSED_EPOCH=0
IS_SUSPENDED=0

WIFI_INTERFACE="bwfm0"
WIFI_PAUSE_FILE="/var/run/pomera_wifi_pause"
WIFI_SUSPEND_STATE="/var/run/pomera_wifi_was_up"
SAVED_BRIGHTNESS="${POMERA_DEFAULT_BRIGHTNESS:-100}"
BRIGHTNESS_FILE="/var/run/pomera_brightness"

while getopts "i:t:p:b:h" opt; do
    case "$opt" in
        i) POLL_INTERVAL="$OPTARG" ;;
        t) SUSPEND_TIMEOUT=$(parse_duration "$OPTARG") ;;
        p) CPU_POLICY="$OPTARG" ;;
        b) SAVED_BRIGHTNESS="$OPTARG" ;;
        h|*)
            echo "Usage: $0 [-i interval_sec] [-t timeout (e.g. 2h, 30m, 7200, 0=disable)] [-p auto|high|100] [-b default_brightness]" >&2
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

# Deep suspend execution helper
# 1. Signals pomera-wifi-watch to pause monitoring (prevents race condition reconnects)
# 2. Shuts down Wi-Fi to prevent net80211 stale pointers & firmware command timeout hangs
# 3. Triple syncs filesystem caches to physical storage
# 4. Triggers hardware APM_IOC_SUSPEND
enter_deep_suspend() {
    logger -t pomera-lid-watch "Initiating safe deep suspend sequence (lid closed for >= ${SUSPEND_TIMEOUT}s)..." 2>/dev/null || true

    # 1. Signal pomera-wifi-watch daemon to pause monitoring (avoid interfering with suspend)
    touch "$WIFI_PAUSE_FILE" 2>/dev/null || true

    # 2. Check if Wi-Fi (bwfm0) is currently active / UP
    rm -f "$WIFI_SUSPEND_STATE"
    if ifconfig "$WIFI_INTERFACE" 2>/dev/null | grep -qE "status: active|UP"; then
        logger -t pomera-lid-watch "Wi-Fi (${WIFI_INTERFACE}) is active. Bringing it down to prevent kernel panic on resume..." 2>/dev/null || true
        touch "$WIFI_SUSPEND_STATE"
        
        # Stop dhclient to prevent background traffic while suspending
        pkill -f "dhclient.*${WIFI_INTERFACE}" 2>/dev/null || true
        
        # Down Wi-Fi interface
        ifconfig "$WIFI_INTERFACE" down 2>/dev/null || true
        sleep 0.5
    fi

    # 3. Flush all filesystem buffers to ensure eMMC/SD storage integrity
    sync
    sync
    sync

    # 4. Trigger hardware suspend
    if [ -x /usr/local/sbin/pomera-suspend ]; then
        /usr/local/sbin/pomera-suspend -f >/dev/null 2>&1 || true
    elif [ -x /etc/pomera-suspend ]; then
        /etc/pomera-suspend -f >/dev/null 2>&1 || true
    fi

    # 5. System resumed from suspend (either power button or lid opening)
    logger -t pomera-lid-watch "Woke up from deep suspend." 2>/dev/null || true
    sync
    IS_SUSPENDED=1
}

# Deferred Wi-Fi restore helper after wake-up
restore_wifi_deferred() {
    # Unpause Wi-Fi monitoring daemon
    rm -f "$WIFI_PAUSE_FILE" 2>/dev/null || true

    if [ -f "$WIFI_SUSPEND_STATE" ]; then
        rm -f "$WIFI_SUSPEND_STATE"
        logger -t pomera-lid-watch "Scheduling Wi-Fi (${WIFI_INTERFACE}) recovery with 8s settle delay..." 2>/dev/null || true
        (
            # Settle delay: kernel SDIO stack re-attaches asynchronously; touching bwfm0 too early panics kernel
            sleep 8
            if [ -x /usr/local/sbin/pomera-wifi-reconnect ]; then
                /usr/local/sbin/pomera-wifi-reconnect >/dev/null 2>&1 || true
            elif [ -f "/etc/hostname.${WIFI_INTERFACE}" ] && [ -x /etc/netstart ]; then
                sh /etc/netstart "$WIFI_INTERFACE" >/dev/null 2>&1 || true
            else
                ifconfig "$WIFI_INTERFACE" up >/dev/null 2>&1 || true
                dhclient "$WIFI_INTERFACE" >/dev/null 2>&1 || true
            fi
        ) &
    fi
}

# Ensure clean exit on SIGTERM/SIGINT (restore normal full power state)
cleanup() {
    rm -f "$WIFI_PAUSE_FILE" "$WIFI_SUSPEND_STATE" 2>/dev/null || true
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
                IS_SUSPENDED=0
                
                # 0. Remember current screen brightness before blanking
                save_brightness

                # 1. Turn OFF screen backlight instantly (0ms latency feel)
                wsconsctl display.brightness=0 >/dev/null 2>&1 || true
                
                # 2. Drop CPU frequency to minimum for lowest battery drain
                sysctl hw.perfpolicy=manual >/dev/null 2>&1 || true
                sysctl hw.setperf=0 >/dev/null 2>&1 || true
            else
                # Check timeout for deep sleep if explicitly enabled (> 0) and not already suspended
                if [ "${SUSPEND_TIMEOUT:-0}" -gt 0 ] 2>/dev/null && [ "$IS_SUSPENDED" -eq 0 ]; then
                    elapsed=$((${SECONDS:-0} - CLOSED_EPOCH))
                    if [ "$elapsed" -ge "$SUSPEND_TIMEOUT" ]; then
                        enter_deep_suspend
                    fi
                fi
            fi
            ;;
        *)
            # Lid is OPEN (or Unknown)
            if [ "$LID_STATE" != "open" ]; then
                LID_STATE="open"
                CLOSED_EPOCH=0
                IS_SUSPENDED=0
                
                # 1. Restore CPU frequency to configured policy (auto scaling or high performance)
                sysctl hw.perfpolicy="$CPU_POLICY" >/dev/null 2>&1 || sysctl hw.setperf=100 >/dev/null 2>&1 || true
                
                # 2. Restore screen backlight to previously saved brightness level
                wsconsctl display.brightness="${SAVED_BRIGHTNESS}%" >/dev/null 2>&1 || wsconsctl display.brightness=100 >/dev/null 2>&1 || true

                # 3. Safely restore Wi-Fi if it was suspended
                restore_wifi_deferred
            fi
            ;;
    esac
    
    sleep "$POLL_INTERVAL"
done
