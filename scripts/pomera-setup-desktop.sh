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

TARGET_HOME=$(awk -F: -v u="$TARGET_USER" '$1 == u {print $6}' /etc/passwd 2>/dev/null)
[ -z "$TARGET_HOME" ] && TARGET_HOME="/home/$TARGET_USER"

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

# 4.2 ~/.vimrc (True Color syntax highlighting & Japanese encoding support)
echo ">> Configuring $TARGET_HOME/.vimrc (Modern True Color & Japanese editor)..."
cat << 'EOF' > "$TARGET_HOME/.vimrc"
syntax on
set background=dark
if has('termguicolors')
  set termguicolors
endif
set number
set autoindent
set smartindent
set encoding=utf-8
set fileencodings=utf-8,cp932,euc-jp,iso-2022-jp
set backspace=indent,eol,start
EOF
chown "$TARGET_USER" "$TARGET_HOME/.vimrc"
chmod 0644 "$TARGET_HOME/.vimrc"

# 4.3 ~/.tmux.conf
echo ">> Configuring $TARGET_HOME/.tmux.conf (Compact status bar for 600px height)..."
cat << 'EOF' > "$TARGET_HOME/.tmux.conf"
# Pomera DM250 (1024x600) Optimized tmux configuration
set -g default-terminal "xterm-256color"
set -g prefix C-a
unbind C-b
bind C-a send-prefix

# Compact status bar design for 600px height (Tango Dark palette)
set -g status-style bg='#2e3436',fg='#ffffff'
set -g status-left '#[fg=#729fcf,bold][#S] '
set -g status-right '#[fg=#fce94f]%m/%d %H:%M '
set -g status-position bottom

# Vim-style pane navigation
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Alt+F1 / Alt+F2 for backlight brightness adjustment (no prefix needed)
bind-key -n M-F1 run-shell "/usr/local/bin/pomera-brightness down"
bind-key -n M-F2 run-shell "/usr/local/bin/pomera-brightness up"
EOF
chown "$TARGET_USER" "$TARGET_HOME/.tmux.conf"
chmod 0644 "$TARGET_HOME/.tmux.conf"

# 4.4 ~/.cwmrc
echo ">> Configuring $TARGET_HOME/.cwmrc (cwm window manager for Pomera)..."
cat << 'EOF' > "$TARGET_HOME/.cwmrc"
# Pomera DM250 1024x600 Optimized cwmrc
fontname "sans-serif:pixelsize=14:antialias=true"
color activeborder "#729fcf"
color inactiveborder "#2e3436"
borderwidth 2
gap 0 0 0 0

# Key Bindings
bind-key M-Return terminal
bind-key M-p "dmenu_run -fn 'sans-serif:pixelsize=14' -nb '#000000' -nf '#ffffff' -sb '#729fcf' -sf '#000000'"
bind-key M-F1 "/usr/local/bin/pomera-brightness down"
bind-key M-F2 "/usr/local/bin/pomera-brightness up"
bind-key M-Down "/usr/local/bin/pomera-brightness down"
bind-key M-Up "/usr/local/bin/pomera-brightness up"
EOF
chown "$TARGET_USER" "$TARGET_HOME/.cwmrc"
chmod 0644 "$TARGET_HOME/.cwmrc"

# 4.5 ~/.Xdefaults (Xft Font Rendering & Crisp Antialiasing)
echo ">> Configuring $TARGET_HOME/.Xdefaults (Xft Antialiasing & LCD Subpixel)..."
cat << 'EOF' > "$TARGET_HOME/.Xdefaults"
! -------------------------------------------------------------
! Xft Font Rendering Optimization for Pomera DM250 (1024x600)
! Grayscale antialiasing (prevents color fringing / dirty dots on dark BG)
! -------------------------------------------------------------
Xft.dpi:        96
Xft.antialias:  1
Xft.hinting:    1
Xft.hintstyle:  hintslight
Xft.rgba:       none
Xft.lcdfilter:  none

! -------------------------------------------------------------
! XTerm fallback configuration
! -------------------------------------------------------------
XTerm*loginShell:        true
XTerm*faceName:          monospace
XTerm*faceSize:          11
XTerm*background:        #000000
XTerm*foreground:        #ffffff
EOF
chown "$TARGET_USER" "$TARGET_HOME/.Xdefaults"
chmod 0644 "$TARGET_HOME/.Xdefaults"

# 4.6 mlterm Configuration (Tango Dark palette, Smooth Japanese fonts)
echo ">> Configuring $TARGET_HOME/.mlterm (Tango Dark & Japanese font rendering)..."
mkdir -p "$TARGET_HOME/.mlterm"
cat << 'EOF' > "$TARGET_HOME/.mlterm/main"
# --- Display & Font ---
use_aafont = true
use_variable_column_width = false
fade_ratio = 100
fontsize = 18
line_space = 0
letter_space = 2
col_size_of_width_a = 1
unicode_full_width = false
unicode_full_width_areas = U+1F000-1FAFF
scrollbar_mode = none

# --- Modern Color & VT Settings ---
termtype = xterm-256color
vt_color_mode = true
use_ansi_colors = true
use_bold_font = true
use_italic_font = true
use_alt_buffer = true
use_clipboard = true

# --- Theme (iTerm2 Tango Dark) ---
fg_color = #ffffff
bg_color = #000000
cursor_fg_color = #000000
cursor_bg_color = #ffffff
EOF

cat << 'EOF' > "$TARGET_HOME/.mlterm/color"
# iTerm2 Tango Dark Color Palette for mlterm
# Standard 8 Colors (0-7)
black=#000000
red=#d81e00
green=#5ea702
yellow=#cfae00
blue=#427ab3
magenta=#89658e
cyan=#00a7aa
white=#dbded8

# High-Intensity / Bold Colors (8-15)
hl_black=#686a66
hl_red=#f54235
hl_green=#99e343
hl_yellow=#fdeb61
hl_blue=#84b0d8
hl_magenta=#bc94b7
hl_cyan=#37e6e8
hl_white=#f1f1f0
EOF

cat << 'EOF' > "$TARGET_HOME/.mlterm/aafont"
DEFAULT = DejaVu Sans Mono
ISO10646_UCS4_1 = DejaVu Sans Mono
ISO10646_UCS4_1_FULLWIDTH = Noto Sans Mono CJK JP
EOF
chown -R "$TARGET_USER" "$TARGET_HOME/.mlterm"
chmod 0700 "$TARGET_HOME/.mlterm"
chmod 0600 "$TARGET_HOME/.mlterm/main" "$TARGET_HOME/.mlterm/color" "$TARGET_HOME/.mlterm/aafont"

# 4.7 ~/.xsession
echo ">> Configuring $TARGET_HOME/.xsession (cwm + mlterm Japanese desktop)..."
cat << 'EOF' > "$TARGET_HOME/.xsession"
#!/bin/sh
export LANG=ja_JP.UTF-8
export LC_CTYPE=ja_JP.UTF-8

# Load X resources (Xft font rendering, terminal styles)
if [ -f "$HOME/.Xdefaults" ]; then
    xrdb -merge "$HOME/.Xdefaults"
fi

# Ensure Caps Lock behaves as Control in X11
setxkbmap -option ctrl:nocaps 2>/dev/null || true

xsetroot -solid "#000000"
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
echo "     - Alt + F1 / F2  : Adjust screen brightness (F1: Dim, F2: Brighten)"
echo "     - Alt + Up / Down: Adjust screen brightness"
echo "     - Ctrl + Alt + q : Close current window"
echo "     - Ctrl + Alt + BackSpace : Exit GUI to CUI"
echo "  2. Setup Japanese Input (IME):"
echo "     Run 'pomera-setup-desktop-jp' to configure uim-anthy!"
echo "  3. Optional display modes:"
echo "     Enable graphical login : $DOAS /usr/local/bin/pomera-gui-toggle gui"
echo "     Revert to CUI console  : $DOAS /usr/local/bin/pomera-gui-toggle cui"
echo ""
