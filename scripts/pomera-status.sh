#!/bin/sh
# pomera-status - Hardware & System Status Reporter for Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Outputs battery level, CPU clock/policy, Wi-Fi status, and system time.
# Usable standalone from CLI, inside tmux status-right, or in prompt hooks.

set -e

MODE="default"
WATCH_INTERVAL=2

while [ $# -gt 0 ]; do
    case "$1" in
        --tmux)
            MODE="tmux"
            shift
            ;;
        --short)
            MODE="short"
            shift
            ;;
        --json)
            MODE="json"
            shift
            ;;
        -w|--watch)
            MODE="watch"
            if [ -n "$2" ] && [ "$2" -eq "$2" ] 2>/dev/null; then
                WATCH_INTERVAL="$2"
                shift 2
            else
                shift
            fi
            ;;
        -h|--help)
            echo "Usage: pomera-status [OPTIONS]"
            echo "Options:"
            echo "  (none)        Pretty colorized status line"
            echo "  --tmux        Optimized for tmux status-right"
            echo "  --short       Compact output for tight spaces / prompt"
            echo "  --json        JSON formatted key-value output"
            echo "  -w, --watch   Live continuous monitoring (default: 2s)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

get_status() {
    # 1. Battery percentage & charging state
    bat_pct="N/A"
    bat_icon="🔋"
    is_charging="no"
    
    if raw_pct=$(sysctl -n hw.sensors.simplebat0.percent0 2>/dev/null); then
        # Format "94.50%" -> "94%"
        bat_pct=$(echo "$raw_pct" | awk -F. '{print $1}')"%"
        pct_num=$(echo "$raw_pct" | awk -F. '{print $1}')
        
        # Check charging state from sensors output
        if sysctl hw.sensors.simplebat0 2>/dev/null | grep -qi "charging"; then
            is_charging="yes"
            bat_icon="⚡"
        elif [ -n "$pct_num" ] && [ "$pct_num" -le 20 ] 2>/dev/null; then
            bat_icon="🪫"
        fi
    fi

    # 2. CPU clock speed & performance policy
    cpu_mhz=$(sysctl -n hw.cpuspeed 2>/dev/null || echo "1200")
    cpu_pol=$(sysctl -n hw.perfpolicy 2>/dev/null || echo "auto")

    # 3. Wi-Fi SSID & Signal
    wifi_ssid=""
    wifi_sig=""
    if ifconfig bwfm0 >/dev/null 2>&1; then
        is_active=""
        raw_ssid=""
        eval "$(ifconfig bwfm0 2>/dev/null | awk '
            /status: active/ { print "is_active=1" }
            /join / { for(i=1;i<=NF;i++) if($i=="join") { print "raw_ssid=" $(i+1); break } }
            /nwid / { for(i=1;i<=NF;i++) if($i=="nwid") { print "raw_ssid=" $(i+1); break } }
            /-[0-9]+dBm/ { for(i=1;i<=NF;i++) if($i ~ /-[0-9]+dBm/) { print "wifi_sig=" $i; break } }
        ')"
        if [ "$is_active" = "1" ] && [ -n "$raw_ssid" ]; then
            wifi_ssid=$(echo "$raw_ssid" | tr -d '"')
        fi
    fi
    [ -z "$wifi_ssid" ] && wifi_ssid="off"

    # 4. Time
    time_str=$(date +'%H:%M')

    # Output formatting by mode
    case "$MODE" in
        tmux)
            # tmux status-right format with colors
            if [ "$is_charging" = "yes" ]; then
                bat_fmt="#[fg=yellow]⚡ ${bat_pct}#[default]"
            else
                bat_fmt="#[fg=green]🔋 ${bat_pct}#[default]"
            fi
            cpu_fmt="#[fg=cyan]⚙️ ${cpu_mhz}MHz#[default]"
            if [ "$wifi_ssid" = "off" ]; then
                wifi_fmt="#[fg=brightblack]📶 off#[default]"
            else
                wifi_fmt="#[fg=blue]📶 ${wifi_ssid}#[default]"
            fi
            echo "${bat_fmt} | ${cpu_fmt} | ${wifi_fmt} | #[fg=white]${time_str}#[default]"
            ;;
        short)
            # Compact format: 95%⚡ 1200MHz HONEYTRAP 13:48
            echo "${bat_pct}${bat_icon} ${cpu_mhz}M ${wifi_ssid} ${time_str}"
            ;;
        json)
            printf '{"battery":"%s","charging":%s,"cpuspeed_mhz":%s,"policy":"%s","wifi":"%s","signal":"%s","time":"%s"}\n' \
                "$bat_pct" \
                "$([ "$is_charging" = "yes" ] && echo "true" || echo "false")" \
                "$cpu_mhz" \
                "$cpu_pol" \
                "$wifi_ssid" \
                "$wifi_sig" \
                "$time_str"
            ;;
        *)
            # Pretty CLI format
            if [ "$wifi_ssid" != "off" ] && [ -n "$wifi_sig" ]; then
                wifi_disp="${wifi_ssid} (${wifi_sig})"
            else
                wifi_disp="${wifi_ssid}"
            fi
            printf "\033[1;32m%s %s\033[0m | \033[1;36m⚙️  %sMHz (%s)\033[0m | \033[1;34m📶 %s\033[0m | \033[1;37m%s\033[0m\n" \
                "$bat_icon" "$bat_pct" "$cpu_mhz" "$cpu_pol" "$wifi_disp" "$time_str"
            ;;
    esac
}

if [ "$MODE" = "watch" ]; then
    # Live top-bar monitoring loop
    trap 'printf "\033[?25h\n"; exit 0' INT TERM
    printf "\033[?25l" # Hide cursor
    while true; do
        printf "\033[H\033[7m" # Move to top, invert colors
        printf " [Pomera DM250 Status]  "
        get_status
        printf "\033[0m\033[K\n"
        sleep "$WATCH_INTERVAL"
    done
else
    get_status
fi
