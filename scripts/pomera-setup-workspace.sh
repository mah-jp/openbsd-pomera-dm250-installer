#!/bin/sh
# pomera-setup-workspace - Automated Workspace & Writing Environment Setup for Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Sets up Pomera DM250 optimized workspace (Vim, tmux, mlterm-fb, Noto fonts)
# and tailored dotfiles for the 1024x600 distraction-free writing environment.

set -e

echo "=========================================================="
echo "✨ Pomera DM250 Workspace & Writing Environment Setup"
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

# 2. Check for local offline package cache or internet connectivity
PKG_DIR=""
for d in /packages /mnt/packages /var/cache/packages; do
    if [ -d "$d" ] && ls "$d"/*.tgz >/dev/null 2>&1; then
        PKG_DIR="$d"
        break
    fi
done

if [ -n "$PKG_DIR" ]; then
    echo "📦 Found offline package cache at $PKG_DIR. Installing locally..."
    $DOAS env PKG_PATH="$PKG_DIR" pkg_add -I vim curl git noto-cjk dmenu fribidi harfbuzz
else
    echo ">> Checking internet connectivity for package download..."
    if ! ping -c 1 -w 3 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -w 3 8.8.8.8 >/dev/null 2>&1; then
        echo "⚠️  Internet connection could not be verified and no offline cache found!"
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

    # Install Packages online (Note: mlterm-fb is pre-bundled; we include fribidi & harfbuzz runtime libs while omitting X11 GTK/DBus bloat)
    echo ">> Installing workspace packages (Vim, curl, git, fonts, dmenu, fribidi, harfbuzz)..."
    $DOAS pkg_add -I vim curl git noto-cjk dmenu fribidi harfbuzz
fi

# 3. Restore patched mlterm-fb (zero-tearing shadowfb & Noto font engine) if bundled
if [ -f /usr/local/share/pomera/mlterm-fb-dm250.tar.gz ]; then
    echo ">> Applying Pomera-optimized mlterm-fb (shadowfb + DECSET 2026)..."
    $DOAS tar -xzf /usr/local/share/pomera/mlterm-fb-dm250.tar.gz -C /
    for bin in /usr/local/bin/mlterm-fb /usr/local/bin/mlterm-fb-pomera; do
        if [ -f "$bin" ]; then
            $DOAS chmod 4755 "$bin"
        fi
    done
    $DOAS ln -sf mlterm-fb /usr/local/bin/mlterm-base
    $DOAS ln -sf mlterm-fb-pomera /usr/local/bin/mlterm-opt
    if [ -f /usr/local/bin/mlterm-fb-pomera ]; then
        echo "   ✅ Dual mlterm-fb setup active:"
        echo "      - /usr/local/bin/mlterm-fb (mlterm-base) -> Baseline verified shadowfb"
        echo "      - /usr/local/bin/mlterm-fb-pomera (mlterm-opt) -> Turbocharged: dirty scanlines + DECSET 2026"
    fi
else
    echo ">> Note: /usr/local/share/pomera/mlterm-fb-dm250.tar.gz not found."
    echo "   Using standard package mlterm. (Run make_sdcard.sh with QEMU builder to enable shadowfb)"
fi

# 4. Deploy 1024x600 Optimized Dotfiles

# 4.1 ~/.profile
echo ">> Configuring $TARGET_HOME/.profile (UTF-8, editor, dual mlterm aliases)..."
cat << 'EOF' > "$TARGET_HOME/.profile"
export LANG=ja_JP.UTF-8
export LC_CTYPE=ja_JP.UTF-8
export TERM=xterm-256color
export EDITOR=vim
export PAGER=less
alias ll='ls -la'
alias mlterm-base='/usr/local/bin/mlterm-fb'
alias mlterm-opt='/usr/local/bin/mlterm-fb-pomera'
alias mlterm-ja='/usr/local/bin/mlterm-opt -M uim:anthy'
alias pstat='pomera-status'
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

# 4.4 mlterm Configuration (Tango Dark palette, Smooth Japanese fonts)
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
DEFAULT = Noto Sans Mono CJK JP
ISO10646_UCS4_1 = Noto Sans Mono CJK JP
ISO10646_UCS4_1_FULLWIDTH = Noto Sans Mono CJK JP
EOF
chown -R "$TARGET_USER" "$TARGET_HOME/.mlterm"
chmod 0700 "$TARGET_HOME/.mlterm"
chmod 0600 "$TARGET_HOME/.mlterm/main" "$TARGET_HOME/.mlterm/color" "$TARGET_HOME/.mlterm/aafont"

# 5. CUI Workspace Information
echo "=========================================================="
echo "🎉 Pomera CUI Workspace & Writing Environment Ready!"
echo "=========================================================="
echo ""
echo "How to use your workspace:
  1. High-Speed Framebuffer Console (mlterm-fb):
     - Run 'mlterm-opt'  (or mlterm-fb-pomera) for the turbocharged build
     - Run 'mlterm-base' (or mlterm-fb) for the baseline shadowfb build
     - Run 'mlterm-ja'   (Launch terminal with direct inline Japanese input)
  2. Text Editing & Multiplexer:
     - Run 'vim' for distraction-free writing (True Color & UTF-8 ready)
     - Run 'tmux' for multi-pane terminal workspace
  3. Setup Japanese Input:
     - Run 'pomera-setup-japanese' to configure direct inline uim-anthy!"

if [ -d "/var/cache/packages" ]; then
    echo "💡 Storage Tip: Offline packages are cached at /var/cache/packages (~180MB)."
    echo "   To reclaim disk space, you can run: $DOAS rm -rf /var/cache/packages"
fi
echo ""
