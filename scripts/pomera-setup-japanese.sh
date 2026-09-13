#!/bin/sh
# pomera-setup-japanese - Automated Japanese Input (IME) Setup for Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Sets up uim-anthy for direct, inline Japanese input under mlterm-fb (CUI console).
# Toggle Japanese input via: Shift + Space, Ctrl + Space, or Zenkaku/Hankaku key.

set -e

echo "=========================================================="
echo "🌸 Pomera DM250 Japanese Input Setup (mlterm-fb + uim-anthy)"
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

# 2. Check for local offline package cache or internet connectivity
PKG_DIR=""
for d in /packages /mnt/packages /var/cache/packages; do
    if [ -d "$d" ] && ls "$d"/anthy*.tgz >/dev/null 2>&1; then
        PKG_DIR="$d"
        break
    fi
done

if [ -n "$PKG_DIR" ]; then
    echo "📦 Found offline package cache at $PKG_DIR. Installing anthy / uim locally..."
    $DOAS env PKG_PATH="$PKG_DIR" pkg_add -I anthy uim 2>/dev/null || $DOAS env PKG_PATH="$PKG_DIR" pkg_add -I anthy
else
    echo ">> Checking internet connectivity..."
    if ! ping -c 1 -w 3 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -w 3 8.8.8.8 >/dev/null 2>&1; then
        echo "⚠️  Internet connection could not be verified!"
        echo "   Please connect to Wi-Fi before running this script."
        printf "Continue anyway? [y/N]: "
        read -r ans
        case "$ans" in
            [yY]*) ;;
            *) echo "Setup aborted."; exit 1 ;;
        esac
    fi

    # 3. Install Anthy dictionary and IME engine packages online
    echo ">> Installing Japanese input method (anthy, uim)..."
    $DOAS pkg_add -I anthy uim 2>/dev/null || $DOAS pkg_add -I anthy
fi

# 4. Configure ~/.uim (Key bindings: Shift+Space, Ctrl+Space, Zenkaku_Hankaku)
echo ">> Configuring $TARGET_HOME/.uim..."
cat << 'EOF' > "$TARGET_HOME/.uim"
;; Pomera DM250 Japanese Input Configuration (uim-anthy)
(define default-im-name 'anthy)

;; Keybindings to toggle Japanese input mode
(define generic-on-key?
  (lambda (key key-state)
    (or (shift-key-mask key-state)
        (control-key-mask key-state)
        (char-equal? key "Zenkaku_Hankaku"))))

(define-key generic-on-key '("<Shift> " "<Control> " "Zenkaku_Hankaku"))
(define-key generic-off-key '("<Shift> " "<Control> " "Zenkaku_Hankaku"))
(define-key anthy-on-key '("<Shift> " "<Control> " "Zenkaku_Hankaku"))
(define-key anthy-off-key '("<Shift> " "<Control> " "Zenkaku_Hankaku"))
(define-key anthy-utf8-on-key '("<Shift> " "<Control> " "Zenkaku_Hankaku"))
(define-key anthy-utf8-off-key '("<Shift> " "<Control> " "Zenkaku_Hankaku"))
EOF
chown "$TARGET_USER" "$TARGET_HOME/.uim"
chmod 0644 "$TARGET_HOME/.uim"

# 5. Enable direct uim-anthy inline input method in ~/.mlterm/main
echo ">> Configuring direct inline IME in $TARGET_HOME/.mlterm/main..."
mkdir -p "$TARGET_HOME/.mlterm"
if [ -f "$TARGET_HOME/.mlterm/main" ]; then
    sed -i '/^input_method *=/d' "$TARGET_HOME/.mlterm/main"
fi
echo "input_method = uim:anthy" >> "$TARGET_HOME/.mlterm/main"
chown -R "$TARGET_USER" "$TARGET_HOME/.mlterm"
chmod 0700 "$TARGET_HOME/.mlterm"
[ -f "$TARGET_HOME/.mlterm/main" ] && chmod 0600 "$TARGET_HOME/.mlterm/main"

# 6. Ensure Japanese locale and mlterm-ja alias in ~/.profile
echo ">> Configuring CUI Japanese environment in $TARGET_HOME/.profile..."
if [ -f "$TARGET_HOME/.profile" ]; then
    sed -i '/alias mlterm-ja=/d' "$TARGET_HOME/.profile"
    echo "alias mlterm-ja='/usr/local/bin/mlterm-opt -M uim:anthy'" >> "$TARGET_HOME/.profile"
fi

echo "=========================================================="
echo "🎉 Japanese Input Setup Complete (Direct Inline uim-anthy)!"
echo "=========================================================="
echo ""
echo "How to use Japanese input on Pomera DM250:"
echo "  1. Start terminal directly:"
echo "     $ mlterm-opt"
echo "     (or launch '$ mlterm-ja')"
echo ""
echo "  2. Toggle Japanese Input directly inline:"
echo "     - Press [Shift + Space] or [Ctrl + Space]"
echo "     - Press [半角 / 全角] key"
echo ""
echo "  3. Beautiful inline kana-kanji conversion right at cursor position!"
echo "     Enjoy distraction-free, zero-lag Japanese writing!"
echo ""
