#!/bin/sh
# /usr/local/sbin/pomera-power-led
# Pomera DM250 Battery & Power LED Indicator Daemon for OpenBSD
#
# Based on harness/netwatchd.sh LED logic by 4noha (MIT License)
# https://github.com/4noha/openbsd-pomera-dm250
# Copyright (c) 2026 4noha
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Controls DM250 two-color LED (gpio1 red_led & green_led):
# - Charging (< 95%):      Orange (Red: 1, Green: 1)
# - Full Charge (>= 95%):  Green  (Red: 0, Green: 1)
# - Discharging (normal):  Off    (Red: 0, Green: 0)
# - Low Battery (<= 15%):  Red    (Red: 1, Green: 0)

POLL_INTERVAL=10
FULL_BAT=95
LOW_BAT=15

# Set LED state: $1=red (0|1), $2=green (0|1)
led_set() {
    gpioctl -q gpio1 red_led   "$1" >/dev/null 2>&1 || gpioctl -q gpio1 8  "$1" >/dev/null 2>&1 || true
    gpioctl -q gpio1 green_led "$2" >/dev/null 2>&1 || gpioctl -q gpio1 12 "$2" >/dev/null 2>&1 || true
}

# Turn off LEDs on clean exit
trap 'led_set 0 0; exit 0' TERM INT

# Ensure pins are initialized if not named yet
gpioctl -q gpio1 8  set out red_led   >/dev/null 2>&1 || true
gpioctl -q gpio1 12 set out green_led >/dev/null 2>&1 || true

last_state=""

while true; do
    # Zero-fork query: fetch percentage and status in a single sysctl call
    raw_bat=$(sysctl -n hw.sensors.simplebat0.percent0 hw.sensors.simplebat0.raw0 2>/dev/null)
    percent="${raw_bat%%.*}"

    case "$raw_bat" in
        *"(charging)"*) raw_status="charging" ;;
        *"(full)"*)     raw_status="full" ;;
        *)              raw_status="discharging" ;;
    esac

    if [ -n "$percent" ] && [ "$percent" -eq "$percent" ] 2>/dev/null; then
        case "$raw_status" in
            charging)
                if [ "$percent" -ge "$FULL_BAT" ]; then
                    want="green"
                else
                    want="orange"
                fi
                ;;
            full)
                want="green"
                ;;
            discharging|*)
                if [ "$percent" -le "$LOW_BAT" ]; then
                    want="red"
                else
                    want="off"
                fi
                ;;
        esac

        if [ "$want" != "$last_state" ]; then
            case "$want" in
                orange) led_set 1 1 ;;
                green)  led_set 0 1 ;;
                red)    led_set 1 0 ;;
                off)    led_set 0 0 ;;
            esac
            last_state="$want"
        fi
    fi

    sleep "$POLL_INTERVAL"
done
