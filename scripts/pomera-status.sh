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
    # 1. CPU load average, performance policy & speed (zero forks)
    raw_load=$(sysctl -n vm.loadavg 2>/dev/null || echo "0.00 0.00 0.00")
    cpu_load="${raw_load%% *}"
    cpu_pol=$(sysctl -n hw.perfpolicy 2>/dev/null || echo "auto")
    cpu_mhz=$(sysctl -n hw.cpuspeed 2>/dev/null || echo "1200")

    # 2. Battery percentage & charging state (pure shell parsing to minimize forks)
    bat_pct="N/A"
    is_charging="no"
    bat_disp="N/A"
    pct_num=""
    
    if raw_pct=$(sysctl -n hw.sensors.simplebat0.percent0 2>/dev/null); then
        # Format "98.00%..." -> "98"
        pct_num="${raw_pct%%.*}"
        bat_pct="${pct_num}%"
        
        # Check raw0 status strictly matching "(charging)" vs "(discharging)"
        raw_state=$(sysctl -n hw.sensors.simplebat0.raw0 2>/dev/null)
        case "$raw_state" in
            *"(charging)"*)
                is_charging="yes"
                bat_disp="${bat_pct} ⚡"
                ;;
            *)
                bat_disp="${bat_pct}"
                ;;
        esac
    fi

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
            # tmux status-right format with colors (stable load average + policy, SSID hidden)
            if [ "$is_charging" = "yes" ]; then
                bat_fmt="#[fg=yellow]${bat_disp}#[default]"
            elif [ -n "$pct_num" ] && [ "$pct_num" -le 20 ] 2>/dev/null; then
                bat_fmt="#[fg=red]${bat_disp}#[default]"
            else
                bat_fmt="#[fg=green]${bat_disp}#[default]"
            fi
            cpu_fmt="#[fg=cyan]${cpu_load} (${cpu_pol})#[default]"
            if [ "$wifi_ssid" = "off" ]; then
                wifi_fmt="#[fg=brightblack]offline#[default]"
            else
                wifi_fmt="#[fg=blue]online#[default]"
            fi
            echo "${bat_fmt} | ${cpu_fmt} | ${wifi_fmt} | #[fg=white]${time_str}#[default]"
            ;;
        short)
            # Compact format: 95% 0.15(auto) online 13:48 (or 95%⚡)
            wifi_short="offline"
            [ "$wifi_ssid" != "off" ] && wifi_short="online"
            if [ "$is_charging" = "yes" ]; then
                echo "${bat_pct}⚡ ${cpu_load} ${wifi_short} ${time_str}"
            else
                echo "${bat_pct} ${cpu_load} ${wifi_short} ${time_str}"
            fi
            ;;
        json)
            printf '{"battery":"%s","charging":%s,"load":"%s","cpuspeed_mhz":%s,"policy":"%s","wifi":"%s","signal":"%s","time":"%s"}\n' \
                "$bat_pct" \
                "$([ "$is_charging" = "yes" ] && echo "true" || echo "false")" \
                "$cpu_load" \
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
                wifi_disp="WiFi: ${wifi_ssid}"
            fi
            if [ "$is_charging" = "yes" ]; then
                bat_color="\033[1;33m"
            elif [ -n "$pct_num" ] && [ "$pct_num" -le 20 ] 2>/dev/null; then
                bat_color="\033[1;31m"
            else
                bat_color="\033[1;32m"
            fi
            printf "${bat_color}%s\033[0m | \033[1;36mload: %s (%s %sMHz)\033[0m | \033[1;34m%s\033[0m | \033[1;37m%s\033[0m\n" \
                "$bat_disp" "$cpu_load" "$cpu_pol" "$cpu_mhz" "$wifi_disp" "$time_str"
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
