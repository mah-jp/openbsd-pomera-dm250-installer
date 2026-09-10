#!/bin/sh
# pomera-font - Easy Font Switcher for mlterm on Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Allows quick switching between favorite coding fonts:
# - udev    : UDEV Gothic JPDOC (BIZ UD + JetBrains Mono, Slashed Zero 0/)
# - moraler : Moralerspace Neon HWJPDOC (Monaspace + BIZ UD, Slashed Zero 0/)
# - noto    : Noto Sans Mono CJK JP (Google Authentic Monospace)

TARGET_HOME="${HOME:-/home/$(id -un)}"
CONFIG_DIR="$TARGET_HOME/.mlterm"
AAFONT_FILE="$CONFIG_DIR/aafont"

mkdir -p "$CONFIG_DIR"

case "$1" in
    udev)
        cat << 'EOF' > "$AAFONT_FILE"
DEFAULT = UDEV Gothic JPDOC
ISO10646_UCS4_1_FULLWIDTH = UDEV Gothic JPDOC
EOF
        echo "✅ Switched mlterm font to: UDEV Gothic JPDOC (Slashed Zero 0/)"
        ;;
    moraler|neon)
        cat << 'EOF' > "$AAFONT_FILE"
DEFAULT = Moralerspace Neon HWJPDOC
ISO10646_UCS4_1_FULLWIDTH = Moralerspace Neon HWJPDOC
EOF
        echo "✅ Switched mlterm font to: Moralerspace Neon HWJPDOC (Slashed Zero 0/)"
        ;;
    noto)
        cat << 'EOF' > "$AAFONT_FILE"
DEFAULT = Noto Sans Mono CJK JP
ISO10646_UCS4_1_FULLWIDTH = Noto Sans Mono CJK JP
EOF
        echo "✅ Switched mlterm font to: Noto Sans Mono CJK JP"
        ;;
    *)
        echo "Usage: $0 [udev | moraler | noto]"
        echo ""
        if [ -f "$AAFONT_FILE" ]; then
            echo "Current mlterm font configuration:"
            head -n 2 "$AAFONT_FILE"
        else
            echo "No custom aafont configuration found."
        fi
        exit 1
        ;;
esac
