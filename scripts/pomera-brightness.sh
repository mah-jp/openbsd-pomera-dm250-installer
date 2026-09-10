#!/bin/sh
# pomera-brightness - Adjust screen backlight brightness for Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Usage:
#   pomera-brightness up     (Increase brightness by 10%)
#   pomera-brightness down   (Decrease brightness by 10%)
#   pomera-brightness <num>  (Set brightness to <num>%, e.g. 50)
#   pomera-brightness        (Show current brightness)

STEP=10
MIN_BRIGHTNESS=10
MAX_BRIGHTNESS=100

# Helper to run wsconsctl (uses doas if not running as root)
run_wsconsctl() {
    if [ "$(id -u)" -eq 0 ]; then
        wsconsctl "$@"
    else
        doas wsconsctl "$@"
    fi
}

cur_raw=$(run_wsconsctl -n display.brightness 2>/dev/null)
if [ -z "$cur_raw" ]; then
    echo "Error: Unable to query display.brightness from wsconsctl." >&2
    exit 1
fi

cur=$(echo "$cur_raw" | tr -d '%' | cut -d. -f1)

case "$1" in
    up|+)
        new=$((cur + STEP))
        [ "$new" -gt "$MAX_BRIGHTNESS" ] && new=$MAX_BRIGHTNESS
        ;;
    down|-)
        new=$((cur - STEP))
        [ "$new" -lt "$MIN_BRIGHTNESS" ] && new=$MIN_BRIGHTNESS
        ;;
    [0-9]*)
        new=$1
        [ "$new" -gt "$MAX_BRIGHTNESS" ] && new=$MAX_BRIGHTNESS
        [ "$new" -lt "$MIN_BRIGHTNESS" ] && new=$MIN_BRIGHTNESS
        ;;
    "")
        echo "Current brightness: ${cur}% (wsconsctl: ${cur_raw})"
        exit 0
        ;;
    *)
        echo "Usage: $(basename "$0") [up|down|PERCENTAGE]"
        exit 1
        ;;
esac

run_wsconsctl display.brightness="${new}%" >/dev/null
echo "Brightness: ${cur}% -> ${new}%"
