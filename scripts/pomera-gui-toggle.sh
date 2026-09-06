#!/bin/sh
# pomera-gui-toggle.sh - Switch between CUI and GUI (X11 / xenodm / cwm) mode on Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Usage:
#   doas /usr/local/bin/pomera-gui-toggle [gui|cui|status]

set -e

ACTION="${1:-status}"

get_status() {
    if rcctl check xenodm >/dev/null 2>&1; then
        echo "Current Display Mode: GUI (xenodm enabled)"
    else
        echo "Current Display Mode: CUI (Console / VT100)"
    fi
}

enable_gui() {
    echo ">> Enabling GUI (X11 / xenodm)..."
    rcctl enable xenodm
    rcctl start xenodm || true
    echo "✅ GUI enabled! xenodm is starting. (Screen will switch to graphical login)"
}

enable_cui() {
    echo ">> Disabling GUI (Reverting to high-speed CUI)..."
    rcctl stop xenodm 2>/dev/null || true
    rcctl disable xenodm
    echo "✅ CUI enabled! System is now running in pure console mode."
}

case "$ACTION" in
    gui|x11)
        enable_gui
        ;;
    cui|console|cli)
        enable_cui
        ;;
    status)
        get_status
        ;;
    toggle)
        if rcctl check xenodm >/dev/null 2>&1; then
            enable_cui
        else
            enable_gui
        fi
        ;;
    *)
        echo "Usage: $0 [gui | cui | toggle | status]"
        exit 1
        ;;
esac
