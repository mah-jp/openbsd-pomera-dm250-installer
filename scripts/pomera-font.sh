#!/bin/sh
# pomera-font - Easy Font Switcher & Downloader for mlterm on Pomera DM250
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Allows switching between recommended coding fonts:
# - udev    : UDEV Gothic JPDOC (by yuru7, SIL OFL 1.1)
# - moraler : Moralerspace Neon HWJPDOC (by yuru7, SIL OFL 1.1)
# - noto    : Noto Sans Mono CJK JP (by Google LLC, SIL OFL 1.1)
#
# If the selected font is not yet installed on the system, it will be downloaded
# and installed automatically from official GitHub releases / package repositories.

set -e

TARGET_HOME="${HOME:-/home/$(id -un)}"
CONFIG_DIR="$TARGET_HOME/.mlterm"
AAFONT_FILE="$CONFIG_DIR/aafont"

if [ "$(id -u)" -eq 0 ]; then
    FONT_BASE_DIR="/usr/local/share/fonts"
else
    FONT_BASE_DIR="$TARGET_HOME/.local/share/fonts"
fi

# Font download URLs (can be overridden via environment variables)
UDEV_GOTHIC_URL="${UDEV_GOTHIC_URL:-https://github.com/yuru7/udev-gothic/releases/download/v2.2.0/UDEVGothic_v2.2.0.zip}"
MORALERSPACE_URL="${MORALERSPACE_URL:-https://github.com/yuru7/moralerspace/releases/download/v2.0.0/MoralerspaceHWJPDOC_v2.0.0.zip}"
# Note: Noto font is installed via OpenBSD package 'noto-cjk'

AUTO_YES=0

is_font_installed() {
    family="$1"
    fc-list : family | grep -Fqx "$family"
}

check_network() {
    echo ">> Checking internet connectivity..."
    if ! curl -sI --connect-timeout 5 https://github.com >/dev/null 2>&1; then
        echo "❌ Error: Cannot connect to the internet."
        echo "   Please check your Wi-Fi connection (e.g. 'doas sh /etc/netstart')."
        return 1
    fi
    return 0
}

extract_zip() {
    archive="$1"
    dest_dir="$2"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$archive" -d "$dest_dir"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m zipfile -e "$archive" "$dest_dir"
    else
        echo "❌ Error: Neither unzip nor python3 is available to extract zip archive."
        return 1
    fi
}

install_github_font() {
    font_name="$1"
    url="$2"
    dest_subdir="$3"

    echo ""
    echo "📦 Font '$font_name' is not installed."
    if [ "$AUTO_YES" != "1" ]; then
        printf "Download and install from GitHub now? [Y/n]: "
        read -r ans
        case "$ans" in
            [nN]*) echo "Installation cancelled."; return 1 ;;
            *) ;;
        esac
    fi

    check_network || return 1

    TARGET_DIR="$FONT_BASE_DIR/$dest_subdir"
    TMP_DIR=$(mktemp -d /tmp/pomera_font_XXXXXX)
    ZIP_FILE="$TMP_DIR/font.zip"

    cleanup() {
        rm -rf "$TMP_DIR"
    }
    trap cleanup EXIT INT TERM

    echo ">> Downloading $font_name..."
    curl -fL --progress-bar "$url" -o "$ZIP_FILE"

    echo ">> Extracting font archive..."
    EXTRACT_DIR="$TMP_DIR/extracted"
    mkdir -p "$EXTRACT_DIR" "$TARGET_DIR"
    extract_zip "$ZIP_FILE" "$EXTRACT_DIR"

    echo ">> Installing font files to $TARGET_DIR..."
    find "$EXTRACT_DIR" -type f \( -name "*.ttf" -o -name "*.otf" \) -exec cp -f {} "$TARGET_DIR/" \;

    echo ">> Updating fontconfig cache..."
    fc-cache -f "$TARGET_DIR"

    cleanup
    trap - EXIT INT TERM
    echo "✅ Font '$font_name' successfully installed!"
    return 0
}

install_noto_pkg() {
    echo ""
    echo "📦 Noto Sans CJK fonts are not installed."
    if [ "$AUTO_YES" != "1" ]; then
        printf "Install OpenBSD noto-cjk package now? [Y/n]: "
        read -r ans
        case "$ans" in
            [nN]*) echo "Installation cancelled."; return 1 ;;
            *) ;;
        esac
    fi

    if [ "$(id -u)" -eq 0 ]; then
        pkg_add -I noto-cjk
    elif command -v doas >/dev/null 2>&1; then
        doas pkg_add -I noto-cjk
    else
        echo "❌ Error: Root or doas privilege required to install noto-cjk package."
        echo "   Please run: doas pkg_add noto-cjk"
        return 1
    fi
    return 0
}

# Parse options
TARGET_FONT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)
            AUTO_YES=1
            shift
            ;;
        -h|--help)
            TARGET_FONT="help"
            shift
            ;;
        *)
            if [ -z "$TARGET_FONT" ]; then
                TARGET_FONT="$1"
            fi
            shift
            ;;
    esac
done

mkdir -p "$CONFIG_DIR"

case "$TARGET_FONT" in
    udev)
        FONT_FAMILY="UDEV Gothic JPDOC"
        if ! is_font_installed "$FONT_FAMILY"; then
            install_github_font "UDEV Gothic" \
                "$UDEV_GOTHIC_URL" \
                "udev-gothic" || exit 1
        fi

        cat << 'EOF' > "$AAFONT_FILE"
DEFAULT = UDEV Gothic JPDOC
ISO10646_UCS4_1 = UDEV Gothic JPDOC
ISO10646_UCS4_1_FULLWIDTH = UDEV Gothic JPDOC
EOF
        echo "✅ Switched mlterm font to: UDEV Gothic JPDOC (Slashed Zero 0/)"
        echo "💡 Note: If mlterm is already running, please restart it to apply the new font."
        ;;

    moraler|neon)
        FONT_FAMILY="Moralerspace Neon HWJPDOC"
        if ! is_font_installed "$FONT_FAMILY"; then
            install_github_font "Moralerspace" \
                "$MORALERSPACE_URL" \
                "moralerspace" || exit 1
        fi

        cat << 'EOF' > "$AAFONT_FILE"
DEFAULT = Moralerspace Neon HWJPDOC
ISO10646_UCS4_1_FULLWIDTH = Moralerspace Neon HWJPDOC
EOF
        echo "✅ Switched mlterm font to: Moralerspace Neon HWJPDOC (Slashed Zero 0/)"
        echo "💡 Note: If mlterm is already running, please restart it to apply the new font."
        ;;

    noto)
        FONT_FAMILY="Noto Sans Mono CJK JP"
        if ! is_font_installed "$FONT_FAMILY"; then
            install_noto_pkg || exit 1
        fi

        cat << 'EOF' > "$AAFONT_FILE"
DEFAULT = Noto Sans Mono CJK JP
ISO10646_UCS4_1 = Noto Sans Mono CJK JP
ISO10646_UCS4_1_FULLWIDTH = Noto Sans Mono CJK JP
EOF
        echo "✅ Switched mlterm font to: Noto Sans Mono CJK JP"
        echo "💡 Note: If mlterm is already running, please restart it to apply the new font."
        ;;

    *)
        echo "Usage: $0 [-y|--yes] [udev | moraler | noto]"
        echo ""
        echo "Available fonts:"
        echo "  udev    : UDEV Gothic JPDOC (Programming font with slashed zero 0/)"
        echo "  moraler : Moralerspace Neon HWJPDOC (Monaspace + BIZ UD Gothic)"
        echo "  noto    : Noto Sans Mono CJK JP (Standard OpenBSD CJK package)"
        echo ""
        echo "Options:"
        echo "  -y, --yes : Automatically confirm font download and installation"
        echo ""
        if [ -f "$AAFONT_FILE" ]; then
            echo "Current mlterm font configuration ($AAFONT_FILE):"
            head -n 3 "$AAFONT_FILE"
        else
            echo "No custom aafont configuration found."
        fi
        exit 1
        ;;
esac
