#!/bin/sh
# pomera-setup-desktop - Automated Desktop & Dev Environment Setup for Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Sets up X11 GUI (cwm, mlterm, Noto CJK Japanese fonts), development tools (vim, tmux),
# and optimized dotfiles for the 1024x600 display.

set -e

echo "=========================================================="
echo "✨ Pomera DM250 OpenBSD Desktop & Dev Setup"
echo "=========================================================="

# 1. Determine target user and home directory
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_USER="$SUDO_USER"
    else
        # Find first non-root regular user in /home
        TARGET_USER=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd 2>/dev/null || echo "pomera")
    fi
    DOAS=""
else
    TARGET_USER="$(id -un)"
    DOAS="doas"
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$TARGET_USER")

if [ ! -d "$TARGET_HOME" ]; then
    echo "❌ Error: Target user home directory $TARGET_HOME does not exist."
    exit 1
fi

echo ">> Target User : $TARGET_USER ($TARGET_HOME)"

# 2. Check Internet Connectivity
echo ">> Checking internet connectivity..."
if ! ping -c 1 -w 3 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -w 3 8.8.8.8 >/dev/null 2>&1; then
    echo "⚠️  Internet connection could not be verified!"
    echo "   Please make sure your Wi-Fi or USB Ethernet is connected."
    echo "   - Wi-Fi config : /etc/hostname.bwfm0 (e.g. 'join SSID wpakey PASS \n inet autoconf')"
    echo "   - Apply network: doas sh /etc/netstart"
    echo ""
    printf "Continue anyway? [y/N]: "
    read -r ans
    case "$ans" in
        [yY]*) ;;
        *) echo "Setup aborted. Connect to internet and run again!"; exit 1 ;;
    esac
fi

# 3. Install Packages
echo ">> Installing essential packages (Vim, tmux, curl, git)..."
$DOAS pkg_add -I vim tmux curl git

echo ">> Installing GUI & fonts (mlterm, Noto CJK, dmenu)..."
$DOAS pkg_add -I mlterm noto-fonts noto-cjk dmenu

# 4. Deploy 1024x600 Optimized Dotfiles

# 4.1 ~/.profile
echo ">> Configuring $TARGET_HOME/.profile (UTF-8, editor)..."
cat << 'EOF' > "$TARGET_HOME/.profile"
export LANG=ja_JP.UTF-8
export LC_CTYPE=ja_JP.UTF-8
export TERM=xterm-256color
export EDITOR=vim
export PAGER=less
alias ll='ls -la'
EOF
chown "$TARGET_USER" "$TARGET_HOME/.profile"
chmod 0644 "$TARGET_HOME/.profile"

# 4.2 ~/.tmux.conf
echo ">> Configuring $TARGET_HOME/.tmux.conf (Compact status bar for 600px height)..."
cat << 'EOF' > "$TARGET_HOME/.tmux.conf"
# Pomera DM250 (1024x600) Optimized tmux configuration
set -g default-terminal "screen-256color"
set -g prefix C-a
unbind C-b
bind C-a send-prefix

# Compact status bar design for 600px height
set -g status-style bg='#1a1b26',fg='#c0caf5'
set -g status-left '#[fg=#7aa2f7,bold][#S] '
set -g status-right '#[fg=#e0af68]%m/%d %H:%M '
set -g status-position bottom

# Vim-style pane navigation
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
EOF
chown "$TARGET_USER" "$TARGET_HOME/.tmux.conf"
chmod 0644 "$TARGET_HOME/.tmux.conf"

# 4.3 ~/.cwmrc
echo ">> Configuring $TARGET_HOME/.cwmrc (cwm window manager for Pomera)..."
cat << 'EOF' > "$TARGET_HOME/.cwmrc"
# Pomera DM250 1024x600 Optimized cwmrc
fontname "sans-serif:pixelsize=14:antialias=true"
color activeborder "#7aa2f7"
color inactiveborder "#24283b"
borderwidth 2
gap 0 0 0 0
command terminal "mlterm"
command dmenu "dmenu_run -fn 'sans-serif:pixelsize=14' -nb '#1a1b26' -nf '#c0caf5' -sb '#7aa2f7' -sf '#1a1b26'"
command brightup "wsconsctl display.brightness=+10"
command brightdown "wsconsctl display.brightness=-10"
bind-key M-Return terminal
bind-key M-p dmenu
bind-key M-Up brightup
bind-key M-Down brightdown
EOF
chown "$TARGET_USER" "$TARGET_HOME/.cwmrc"
chmod 0644 "$TARGET_HOME/.cwmrc"

# 4.4 ~/.Xdefaults (Xft Font Rendering & Crisp Antialiasing)
echo ">> Configuring $TARGET_HOME/.Xdefaults (Xft Antialiasing & LCD Subpixel)..."
cat << 'EOF' > "$TARGET_HOME/.Xdefaults"
! -------------------------------------------------------------
! Xft Font Rendering Optimization for Pomera DM250 (1024x600)
! -------------------------------------------------------------
Xft.dpi:        96
Xft.antialias:  1
Xft.hinting:    1
Xft.hintstyle:  hintslight
Xft.rgba:       rgb
Xft.lcdfilter:  lcddefault

! -------------------------------------------------------------
! XTerm fallback configuration
! -------------------------------------------------------------
XTerm*loginShell:        true
XTerm*faceName:          monospace
XTerm*faceSize:          11
XTerm*background:        #1a1b26
XTerm*foreground:        #c0caf5
EOF
chown "$TARGET_USER" "$TARGET_HOME/.Xdefaults"
chmod 0644 "$TARGET_HOME/.Xdefaults"

# 4.5 mlterm Configuration (~/.mlterm/main & ~/.mlterm/aafont)
echo ">> Configuring $TARGET_HOME/.mlterm (Smooth Japanese font rendering)..."
mkdir -p "$TARGET_HOME/.mlterm"
cat << 'EOF' > "$TARGET_HOME/.mlterm/main"
use_anti_alias = true
use_variable_column_width = false
fontsize = 15
type_engine = xft
line_space = 2
fg_color = #c0caf5
bg_color = #1a1b26
cursor_fg_color = #1a1b26
cursor_bg_color = #7aa2f7
scrollbar_mode = none
EOF

cat << 'EOF' > "$TARGET_HOME/.mlterm/aafont"
DEFAULT = Noto Sans Mono CJK JP
ISO10646_UCS4_1_FULLWIDTH = Noto Sans Mono CJK JP
EOF
chown -R "$TARGET_USER" "$TARGET_HOME/.mlterm"
chmod 0700 "$TARGET_HOME/.mlterm"
chmod 0600 "$TARGET_HOME/.mlterm/main" "$TARGET_HOME/.mlterm/aafont"

# 4.6 ~/.xsession
echo ">> Configuring $TARGET_HOME/.xsession (cwm + mlterm Japanese desktop)..."
cat << 'EOF' > "$TARGET_HOME/.xsession"
#!/bin/sh
export LANG=ja_JP.UTF-8
export LC_CTYPE=ja_JP.UTF-8

# Load X resources (Xft font rendering, terminal styles)
if [ -f "$HOME/.Xdefaults" ]; then
    xrdb -merge "$HOME/.Xdefaults"
fi

xsetroot -solid "#1a1b26"
mlterm &
exec cwm
EOF
chown "$TARGET_USER" "$TARGET_HOME/.xsession"
chmod 0755 "$TARGET_HOME/.xsession"

# 5. Optional GUI display mode
echo "=========================================================="
echo "🎉 Desktop & Development Environment Setup Complete!"
echo "=========================================================="
echo ""
echo "How to use your new environment:"
echo "  1. Start GUI manually : run 'startx'"
echo "     - Alt + Enter    : Open terminal (mlterm)"
echo "     - Alt + Up/Down  : Adjust screen brightness"
echo "     - Ctrl + Alt + q : Close current window"
echo "     - Ctrl + Alt + BackSpace : Exit GUI to CUI"
echo "  2. Setup Japanese Input (IME):"
echo "     Run 'pomera-setup-desktop-jp' to configure uim-anthy!"
echo "  3. Optional display modes:"
echo "     Enable graphical login : $DOAS /usr/local/bin/pomera-gui-toggle gui"
echo "     Revert to CUI console  : $DOAS /usr/local/bin/pomera-gui-toggle cui"
echo ""
