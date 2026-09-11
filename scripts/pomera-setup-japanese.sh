#!/bin/sh
# pomera-setup-japanese - Automated Japanese Input (IME) Setup for Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Sets up uim and uim-anthy for seamless Japanese input under X11 (cwm + mlterm).
# Toggle Japanese input via: Shift + Space, Ctrl + Space, or Zenkaku/Hankaku key.

set -e

echo "=========================================================="
echo "🌸 Pomera DM250 Japanese Input Setup (uim-anthy)"
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
    if [ -d "$d" ] && ls "$d"/uim*.tgz >/dev/null 2>&1; then
        PKG_DIR="$d"
        break
    fi
done

if [ -n "$PKG_DIR" ]; then
    echo "📦 Found offline package cache at $PKG_DIR. Installing uim and uim-anthy locally..."
    $DOAS env PKG_PATH="$PKG_DIR" pkg_add -I uim uim-anthy
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

    # 3. Install uim and Anthy packages online
    echo ">> Installing Japanese input method (uim, uim-anthy)..."
    $DOAS pkg_add -I uim uim-anthy
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
EOF
chown "$TARGET_USER" "$TARGET_HOME/.uim"
chmod 0644 "$TARGET_HOME/.uim"

# 5. Update ~/.xsession to launch uim-xim
echo ">> Updating $TARGET_HOME/.xsession with uim environment..."
if [ ! -f "$TARGET_HOME/.xsession" ]; then
    cat << 'EOF' > "$TARGET_HOME/.xsession"
#!/bin/sh
export LANG=ja_JP.UTF-8
export LC_CTYPE=ja_JP.UTF-8
export XMODIFIERS=@im=uim
export GTK_IM_MODULE=uim
export QT_IM_MODULE=uim

if [ -f "$HOME/.Xdefaults" ]; then
    xrdb -merge "$HOME/.Xdefaults"
fi

uim-xim &
xsetroot -solid "#1a1b26"
mlterm &
exec cwm
EOF
else
    # Inject IME variables if not present
    if ! grep -q "XMODIFIERS" "$TARGET_HOME/.xsession"; then
        TMP_XSESSION=$(mktemp)
        {
            echo 'export XMODIFIERS=@im=uim'
            echo 'export GTK_IM_MODULE=uim'
            echo 'export QT_IM_MODULE=uim'
            echo 'uim-xim &'
            cat "$TARGET_HOME/.xsession"
        } > "$TMP_XSESSION"
        cat "$TMP_XSESSION" > "$TARGET_HOME/.xsession"
        rm -f "$TMP_XSESSION"
    fi
fi
chown "$TARGET_USER" "$TARGET_HOME/.xsession"
chmod 0755 "$TARGET_HOME/.xsession"

# 6. Ensure .xinitrc points to .xsession
ln -sf .xsession "$TARGET_HOME/.xinitrc"
chown -h "$TARGET_USER" "$TARGET_HOME/.xinitrc"

echo "=========================================================="
echo "🎉 Japanese Input Setup Complete!"
echo "=========================================================="
echo ""
echo "How to toggle Japanese input in X11 / mlterm:"
echo "  - Press [Shift + Space] or [Ctrl + Space]"
echo "  - Press [半角 / 全角] key"
echo ""
echo "Start or restart X11 to apply: run 'startx'"
echo ""
