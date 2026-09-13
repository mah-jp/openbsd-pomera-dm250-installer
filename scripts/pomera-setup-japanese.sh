#!/bin/sh
# pomera-setup-japanese - Automated Japanese Input (SKK) Setup for Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Sets up built-in SKK with large dictionary (SKK-JISYO.L) for ultra-fast,
# zero-lag inline Japanese input under mlterm-fb (CUI console).
# Toggle Japanese input via: Shift + Space, Ctrl + Space.

set -e

echo "=========================================================="
echo "🌸 Pomera DM250 Japanese Input Setup (mlterm-fb + SKK)"
echo "=========================================================="

# 1. Determine target user and home directory
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd 2>/dev/null || echo "pomera")
    fi
    DOAS=""
else
    TARGET_USER="$(id -un)"
    DOAS="doas"
fi

TARGET_HOME=$(awk -F: -v u="$TARGET_USER" '$1 == u {print $6}' /etc/passwd 2>/dev/null)
[ -z "$TARGET_HOME" ] && TARGET_HOME="/home/$TARGET_USER"

if [ ! -d "$TARGET_HOME" ]; then
    echo "❌ Error: Target user home directory $TARGET_HOME does not exist."
    exit 1
fi

echo ">> Target User : $TARGET_USER ($TARGET_HOME)"

# 2. Check and install SKK dictionary (SKK-JISYO.L)
SKK_DICT="/usr/local/share/skk/SKK-JISYO.L"
if [ -f "$SKK_DICT" ]; then
    echo "✅ Found SKK Large Dictionary at $SKK_DICT."
else
    echo ">> SKK dictionary not found. Searching packages..."
    PKG_DIR=""
    for d in /packages /mnt/packages /var/cache/packages; do
        if [ -d "$d" ] && ls "$d"/skk-jisyo*.tgz >/dev/null 2>&1; then
            PKG_DIR="$d"
            break
        fi
    done

    if [ -n "$PKG_DIR" ]; then
        echo "📦 Found offline package cache at $PKG_DIR. Installing skk-jisyo locally..."
        $DOAS env PKG_PATH="$PKG_DIR" pkg_add -I skk-jisyo
    else
        echo ">> Checking internet connectivity..."
        if ! ping -c 1 -w 3 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -w 3 8.8.8.8 >/dev/null 2>&1; then
            echo "⚠️  Internet connection could not be verified!"
            echo "   Please connect to Wi-Fi or mount installation media before running this script."
            printf "Continue anyway? [y/N]: "
            read -r ans
            case "$ans" in
                [yY]*) ;;
                *) echo "Setup aborted."; exit 1 ;;
            esac
        fi

        echo ">> Installing skk-jisyo package online..."
        $DOAS pkg_add -I skk-jisyo
    fi
fi

# 3. Configure ~/.mlterm/key (Key bindings: Shift+Space, Ctrl+Space for IME toggle)
echo ">> Configuring $TARGET_HOME/.mlterm/key..."
mkdir -p "$TARGET_HOME/.mlterm"

cat << 'EOF' > "$TARGET_HOME/.mlterm/key"
# Pomera DM250 Japanese IME Toggle Keybindings
Shift+space = im_toggle
Control+space = im_toggle
EOF

# 4. Configure ~/.mlterm/main (Enable SKK input method with large dictionary)
echo ">> Configuring SKK input method in $TARGET_HOME/.mlterm/main..."
if [ -f "$TARGET_HOME/.mlterm/main" ]; then
    sed -i '/^input_method *=/d' "$TARGET_HOME/.mlterm/main"
fi
cat << EOF >> "$TARGET_HOME/.mlterm/main"

# --- Japanese Input Method (SKK) ---
input_method = skk:dict=${SKK_DICT}
EOF

# 5. Configure ~/.mlterm/skk optional preferences
cat << 'EOF' > "$TARGET_HOME/.mlterm/skk"
# Pomera DM250 SKK Preferences
# Sticky shift key or additional dictionary configurations can be specified here.
EOF

# Set proper permissions for .mlterm directory
chown -R "$TARGET_USER" "$TARGET_HOME/.mlterm"
chmod 0700 "$TARGET_HOME/.mlterm"
chmod 0600 "$TARGET_HOME/.mlterm/main" "$TARGET_HOME/.mlterm/key" "$TARGET_HOME/.mlterm/skk"

# Ensure mlterm framebuffer binaries have setuid root to access /dev/ttyC0
[ -f /usr/local/bin/mlterm-fb ] && $DOAS chmod 4755 /usr/local/bin/mlterm-fb
[ -f /usr/local/bin/mlterm-fb-pomera ] && $DOAS chmod 4755 /usr/local/bin/mlterm-fb-pomera

# 6. Ensure Japanese locale, SKK_DICTIONARY, and aliases in ~/.profile
echo ">> Configuring CUI Japanese environment in $TARGET_HOME/.profile..."
if [ -f "$TARGET_HOME/.profile" ]; then
    sed -i '/export SKK_DICTIONARY=/d' "$TARGET_HOME/.profile"
    sed -i '/alias mlterm-ja=/d' "$TARGET_HOME/.profile"
    sed -i '/alias mlterm-skk=/d' "$TARGET_HOME/.profile"

    cat << EOF >> "$TARGET_HOME/.profile"
export SKK_DICTIONARY="${SKK_DICT}"
alias mlterm-ja='/usr/local/bin/mlterm-opt -M skk:dict=${SKK_DICT}'
alias mlterm-skk='/usr/local/bin/mlterm-opt -M skk:dict=${SKK_DICT}'
EOF
fi

echo "=========================================================="
echo "🎉 Japanese Input Setup Complete (Direct Inline SKK)!"
echo "=========================================================="
echo ""
echo "How to use SKK on Pomera DM250:"
echo "  1. Launch terminal:"
echo "     $ mlterm-opt"
echo "     (or launch '$ mlterm-ja')"
echo ""
echo "  2. Toggle Japanese Mode ON / OFF:"
echo "     - Press [Shift + Space] or [Ctrl + Space]"
echo "     - When active, '[かな]' appears at cursor/status."
echo ""
echo "  3. Fast Typing Rules:"
echo "     - Hiragana   : Type lowercase (e.g. 'nihongo' -> 'にほんご')"
echo "     - Kanji      : Type FIRST letter capitalized with Shift"
echo "                    (e.g. 'Nihon' -> '▽にほん' -> press [Space] -> '日本')"
echo "     - Okurigana  : Type word start with Shift, then okurigana start with Shift"
echo "                    (e.g. 'Omo' + 'I' -> '▽おも*い' -> press [Space] -> '思い')"
echo "     - Katakana   : Press 'q' to toggle Hiragana <-> Katakana"
echo "     - Confirm    : Press [Enter] or [Ctrl + j] (or just keep typing)"
echo "     - Cancel     : Press [Ctrl + g]"
echo ""
