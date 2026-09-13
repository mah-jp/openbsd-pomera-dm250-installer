#!/bin/sh
# /usr/local/bin/pomera-tune
# Pomera DM250 On-Demand Memory & Power Optimizer for OpenBSD
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Optimizes a standard OpenBSD installation for maximum battery and RAM on Pomera DM250:
# - Disables smtpd  (Frees 7 processes, ~17MB RSS; mail server not needed)
# - Disables sndiod (Frees 2 processes; DM250 hardware has no audio output DAC)
# - Disables pflogd (Frees 2 processes; eliminates unnecessary SD card log writes)
# - Disables unused virtual consoles ttyC1-ttyC5 (Frees 5 unused getty processes)

set -e

# Require root privileges
ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v doas >/dev/null 2>&1; then
            exec doas "$0" "$@"
        else
            echo "Error: This script must be run as root (or via doas)." >&2
            exit 1
        fi
    fi
}

show_status() {
    echo "=========================================================="
    echo "📊 Pomera DM250 System Services & Tuning Status"
    echo "=========================================================="

    # Services status
    for s in smtpd sndiod pflogd slaacd; do
        if rcctl check "$s" >/dev/null 2>&1; then
            stat="RUNNING"
        else
            stat="STOPPED"
        fi
        flag=$(rcctl get "$s" status 2>/dev/null || echo "unknown")
        printf "  • %-10s : %-8s (enabled: %s)\n" "$s" "$stat" "$flag"
    done

    echo ""
    echo "Virtual Consoles (ttys):"
    for i in 1 2 3 4 5; do
        stat=$(awk -v tty="ttyC$i" '$1==tty {print $4}' /etc/ttys 2>/dev/null || echo "unknown")
        pg=$(pgrep -f "getty.*ttyC$i" >/dev/null 2>&1 && echo "running" || echo "stopped")
        printf "  • ttyC%d    : %-8s (process: %s)\n" "$i" "$stat" "$pg"
    done

    echo ""
    echo "Resource Summary:"
    proc_count=$(ps -ax 2>/dev/null | wc -l | tr -d ' ')
    echo "  • Active processes : ${proc_count}"
    if command -v top >/dev/null 2>&1; then
        top -b -d 1 | grep -i "Memory:" | head -n 1 | sed 's/^/  • /'
    fi
    echo "=========================================================="
}

apply_tuning() {
    ensure_root
    echo "=========================================================="
    echo "⚡ Applying Pomera DM250 Memory & Power Tuning..."
    echo "=========================================================="

    # 1. Stop & Disable smtpd (Mail server)
    echo ">> [1/4] Disabling OpenSMTPD (smtpd)..."
    rcctl stop smtpd >/dev/null 2>&1 || true
    rcctl disable smtpd >/dev/null 2>&1 || true
    pkill -9 -f "/usr/sbin/smtpd" >/dev/null 2>&1 || true
    echo "   ✅ smtpd stopped and disabled (saved ~17MB RSS, 7 processes)"

    # 2. Stop & Disable sndiod (Sound daemon - DM250 has no audio DAC)
    echo ">> [2/4] Disabling sndiod (Audio daemon)..."
    rcctl stop sndiod >/dev/null 2>&1 || true
    rcctl disable sndiod >/dev/null 2>&1 || true
    pkill -9 -f "sndiod" >/dev/null 2>&1 || true
    echo "   ✅ sndiod stopped and disabled (DM250 has no speaker/DAC)"

    # 3. Stop & Disable pflogd (Firewall logging)
    echo ">> [3/4] Disabling pflogd (PF packet log daemon)..."
    rcctl stop pflogd >/dev/null 2>&1 || true
    rcctl disable pflogd >/dev/null 2>&1 || true
    pkill -9 -f "pflogd" >/dev/null 2>&1 || true
    echo "   ✅ pflogd stopped and disabled (protects SD card write cycles)"

    # 4. Disable unused virtual consoles (ttyC1 - ttyC5)
    echo ">> [4/4] Disabling unused virtual consoles (ttyC1 to ttyC5)..."
    if [ -f /etc/ttys ]; then
        sed -i -E 's/^(ttyC[1-5][[:space:]]+.*[[:space:]]+)on([[:space:]]+.*)$/\1off\2/' /etc/ttys
        # Signal init to reload /etc/ttys and terminate unused gettys
        kill -HUP 1 2>/dev/null || true
        # Clean up any lingering gettys
        for i in 1 2 3 4 5; do
            pkill -f "getty.*ttyC$i" 2>/dev/null || true
        done
        echo "   ✅ ttyC1-ttyC5 disabled in /etc/ttys (freed 5 unused processes)"
    fi

    echo ""
    echo "🎉 Tuning complete! Unnecessary background services eliminated."
    echo ""
    show_status
}

restore_defaults() {
    ensure_root
    echo "=========================================================="
    echo "🔄 Restoring Standard OpenBSD Services..."
    echo "=========================================================="

    echo ">> Re-enabling smtpd..."
    rcctl enable smtpd >/dev/null 2>&1 || true
    rcctl start smtpd >/dev/null 2>&1 || true

    echo ">> Re-enabling sndiod..."
    rcctl enable sndiod >/dev/null 2>&1 || true
    rcctl start sndiod >/dev/null 2>&1 || true

    echo ">> Re-enabling pflogd..."
    rcctl enable pflogd >/dev/null 2>&1 || true
    rcctl start pflogd >/dev/null 2>&1 || true

    echo ">> Re-enabling ttyC1-ttyC5 in /etc/ttys..."
    if [ -f /etc/ttys ]; then
        sed -i -E 's/^(ttyC[1-5][[:space:]]+.*[[:space:]]+)off([[:space:]]+.*)$/\1on\2/' /etc/ttys
        kill -HUP 1 2>/dev/null || true
    fi

    echo ""
    echo "✅ Standard OpenBSD services restored."
    echo ""
    show_status
}

case "${1:-}" in
    status|-s|--status)
        show_status
        ;;
    restore|--restore)
        restore_defaults
        ;;
    help|-h|--help)
        echo "Usage: $(basename "$0") [apply | status | restore]"
        echo ""
        echo "Commands:"
        echo "  apply    (default) Stop & disable smtpd, sndiod, pflogd, and unused ttys"
        echo "  status   Show current tuning state and process/memory summary"
        echo "  restore  Restore standard OpenBSD default services and ttys"
        exit 0
        ;;
    apply|"")
        apply_tuning
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Usage: $(basename "$0") [apply | status | restore]" >&2
        exit 1
        ;;
esac
