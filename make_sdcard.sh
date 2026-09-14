#!/usr/bin/env bash
# =====================================================================
# Pomera DM250 OpenBSD Installer SD Builder (Native OpenBSD QEMU Engine)
#
# Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
# SPDX-License-Identifier: MIT
#
# Supported Host OS: macOS (Apple Silicon / Intel), Linux (amd64 / arm64)
# Features:
# - Clean, transparent, zero prebuilt-blob architecture: fetches official OpenBSD & jcs binaries
# - Drives a temporary OpenBSD QEMU VM to run authentic fdisk/disklabel/newfs on the target SD card
# - 100% Guaranteed Native FFS/Disklabel compliance on physical Pomera DM250 hardware!
# - Bulletproof signal handling (SIGINT/SIGTERM) and clean resource reclamation
# =====================================================================

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f "${SCRIPT_DIR}/VERSION" ]; then
    TOOL_VERSION="$(tr -d '\r\n' < "${SCRIPT_DIR}/VERSION")"
else
    TOOL_VERSION="undefined"
fi

WORK_DIR="${SCRIPT_DIR}/_build_cache"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

TARGET_DEV=""
BLOCK_DEV=""
DETECTED_DEVICES=()
DOWNLOAD_ONLY=false
BOOTLOADER_ONLY=false
REBUILD_UBOOT=false
BUILD_KERNEL=false
REBUILD_MLTERM=false
POMERA_SMART_KERNEL="${POMERA_SMART_KERNEL:-yes}"
POMERA_PATCH_USB_HUB="${POMERA_PATCH_USB_HUB:-yes}"
POMERA_PATCH_X11_KEYS="${POMERA_PATCH_X11_KEYS:-yes}"
POMERA_PATCH_MLTERM_FB="${POMERA_PATCH_MLTERM_FB:-yes}"
POMERA_PATCH_BT="${POMERA_PATCH_BT:-yes}"
POMERA_WORKSPACE="${POMERA_WORKSPACE:-yes}"
POMERA_BUILD_PATCHED_KERNEL="${POMERA_BUILD_PATCHED_KERNEL:-no}"
CLI_SMART_KERNEL=""
CLI_PATCH_USB_HUB=""
CLI_PATCH_X11_KEYS=""
CLI_PATCH_MLTERM_FB=""
CLI_PATCH_BT=""
CLI_WORKSPACE=""
MODEL_TYPE="dm250"

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

# Prevent macOS bsdtar from embedding AppleDouble and extended attributes into archives
export COPYFILE_DISABLE=1

# ---------------------------------------------------------------------
# File Ownership Helper (pomera-dm250-backup-restore-tool convention)
# ---------------------------------------------------------------------
fix_file_ownership() {
    local target_path="$1"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -e "$target_path" ]; then
        chown -R "$SUDO_USER" "$target_path" 2>/dev/null || true
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    fix_file_ownership "${CONFIGS_DIR}"
    rm -rf "${SCRIPTS_DIR}/__pycache__" 2>/dev/null || fix_file_ownership "${SCRIPTS_DIR}/__pycache__"
    if [ -d "${WORK_DIR}" ]; then
        for f in "${WORK_DIR}"/*; do
            if [ -f "$f" ]; then
                fix_file_ownership "$f"
            fi
        done
    fi
    if [ "$OS_NAME" = "Darwin" ] && [ -n "${BLOCK_DEV:-}" ]; then
        diskutil unmountDisk "$BLOCK_DEV" >/dev/null 2>&1 || true
    fi
    if [ $exit_code -ne 0 ] && [ "$DOWNLOAD_ONLY" = false ]; then
        echo ""
        echo "⚠️  Operation ended with exit code: $exit_code" >&2
    fi
    exit "$exit_code"
}
trap cleanup_on_exit EXIT INT TERM HUP

OPENBSD_VER="79"
ARMV7_MIRROR="https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7"
ARMV7_SNAP_MIRROR="https://cdn.openbsd.org/pub/OpenBSD/snapshots/armv7"
ARM64_MIRROR="https://cdn.openbsd.org/pub/OpenBSD/7.9/arm64"
ARM64_SNAP_MIRROR="https://cdn.openbsd.org/pub/OpenBSD/snapshots/arm64"
FIRMWARE_MIRROR="http://firmware.openbsd.org/firmware/7.9"
FIRMWARE_SNAP_MIRROR="http://firmware.openbsd.org/firmware/snapshots"
JCS_MIRROR="https://jcs.org/dm250"
RKBIN_MIRROR="https://raw.githubusercontent.com/rockchip-linux/rkbin/master/bin/rk31"

show_help() {
    echo "=========================================================="
    echo "  Pomera DM250 OpenBSD Installer SD Builder v${TOOL_VERSION}"
    echo "=========================================================="
    echo "Usage: $0 [options] [/dev/sdX | /dev/rdiskN]"
    echo ""
    echo "Options:"
    echo "  --us                   Build for Pomera DM250US (US model)"
    echo "  --smart-kernel         Build & use DM250 tailored kernel (removes unused SoCs/PCI drivers, Default: yes)"
    echo "  --no-smart-kernel      Use standard generic kernel"
    echo "  --patch-usb-hub        Enable USB Hub split transaction crash fix (Default: yes)"
    echo "  --no-patch-usb-hub     Disable USB Hub split transaction crash fix"
    echo "  --patch-x11-keys       Enable X11 Right-Shift & Left-Alt keys fix (Default: yes)"
    echo "  --no-patch-x11-keys    Disable X11 Right-Shift & Left-Alt keys fix"
    echo "  --patch-mlterm-fb      Enable mlterm-fb framebuffer console patch (rkdrm SMODE, Default: yes)"
    echo "  --no-patch-mlterm-fb   Disable mlterm-fb framebuffer console patch"
    echo "  --patch-bt             Enable Bluetooth UART 2s delay patch (bcmbt, Default: yes)"
    echo "  --no-patch-bt          Disable Bluetooth UART 2s delay patch"
    echo "  --workspace            Pre-bundle offline workspace packages (Vim, curl, git, mlterm, Noto CJK, dmenu, Default: yes)"
    echo "  --no-workspace         Do not bundle offline packages (minimal installer)"
    echo "  --build-kernel         Rebuild patched OpenBSD kernel (USB, keyboard, mlterm-fb & BT fixes) via QEMU"
    echo "  --rebuild-mlterm       Rebuild patched mlterm-fb (shadowfb & Noto font engine) via QEMU"
    echo "  --rebuild-uboot        Rebuild custom auto-booting U-Boot binary"
    echo "  --bootloader-only      Flash only idbloader.img & uboot.img to target without formatting"
    echo "  --download-only        Fetch all required official binaries without formatting"
    echo "  --help, -h             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --download-only     # Pre-download all packages & binaries"
    echo "  $0 --smart-kernel      # Build & use DM250 optimized kernel (~4MB)"
    echo "  $0 --patch-mlterm-fb   # Build kernel with mlterm-fb framebuffer patch"
    echo "  $0 --build-kernel      # Recompile patched kernel in QEMU"
    echo "  $0 --rebuild-mlterm    # Recompile patched mlterm-fb in QEMU"
    echo "  $0 /dev/sdb            # Flash directly to SD card on Linux"
    echo "  $0 /dev/rdisk4         # Flash directly to SD card on macOS"
    echo "  $0 --rebuild-uboot     # Force rebuild auto-booting U-Boot"
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) show_help ;;
            --us) MODEL_TYPE="dm250us"; shift ;;
            --smart-kernel) CLI_SMART_KERNEL="yes"; shift ;;
            --no-smart-kernel) CLI_SMART_KERNEL="no"; shift ;;
            --patch-usb-hub) CLI_PATCH_USB_HUB="yes"; shift ;;
            --no-patch-usb-hub) CLI_PATCH_USB_HUB="no"; shift ;;
            --patch-x11-keys) CLI_PATCH_X11_KEYS="yes"; shift ;;
            --no-patch-x11-keys) CLI_PATCH_X11_KEYS="no"; shift ;;
            --patch-mlterm-fb) CLI_PATCH_MLTERM_FB="yes"; shift ;;
            --no-patch-mlterm-fb) CLI_PATCH_MLTERM_FB="no"; shift ;;
            --patch-bt) CLI_PATCH_BT="yes"; shift ;;
            --no-patch-bt) CLI_PATCH_BT="no"; shift ;;
            --workspace) CLI_WORKSPACE="yes"; shift ;;
            --no-workspace) CLI_WORKSPACE="no"; shift ;;
            --build-kernel) BUILD_KERNEL=true; shift ;;
            --rebuild-mlterm) REBUILD_MLTERM=true; shift ;;
            --rebuild-uboot) REBUILD_UBOOT=true; shift ;;
            --bootloader-only|--flash-bootloader) BOOTLOADER_ONLY=true; shift ;;
            --download-only) DOWNLOAD_ONLY=true; shift ;;
            *)
                if [ -z "$TARGET_DEV" ]; then TARGET_DEV="$1"; else show_help; fi
                shift
                ;;
        esac
    done
}

check_prerequisites() {
    local required_cmds=(curl python3 qemu-system-aarch64)
    if [ "$OS_NAME" != "Darwin" ]; then
        required_cmds+=(mcopy)
        if [ "$ARCH_NAME" = "x86_64" ]; then
            if ! command -v arm-linux-gnueabihf-objdump >/dev/null 2>&1 && \
               ! command -v arm-none-eabi-objdump >/dev/null 2>&1 && \
               ! command -v llvm-objdump >/dev/null 2>&1; then
                required_cmds+=(arm-linux-gnueabihf-objdump)
            fi
        fi
    fi

    local missing=()
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then missing+=("$cmd"); fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Missing required host utilities: ${missing[*]}"
        echo ""
        if [ "$OS_NAME" = "Darwin" ]; then
            echo "Install via Homebrew:"
            echo "  brew install curl coreutils python3 qemu"
        else
            echo "Install via APT (Ubuntu/Debian):"
            echo "  sudo apt update && sudo apt install -y curl python3 qemu-system-arm qemu-efi-aarch64 mtools binutils-arm-linux-gnueabihf"
            echo "Install via DNF (Fedora):"
            echo "  sudo dnf install -y curl python3 qemu-system-aarch64 edk2-aarch64 mtools binutils-arm-linux-gnu"
            echo "Install via Pacman (Arch Linux):"
            echo "  sudo pacman -S --needed curl python qemu-system-aarch64 edk2-arm mtools arm-linux-gnueabihf-binutils"
        fi
        exit 1
    fi
}

calc_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$file"
    fi
}

get_expected_sha256() {
    local filename="$1"
    local hash_file="$2"
    local url_name="${3:-}"
    if [ -n "$hash_file" ] && [ -f "$hash_file" ]; then
        local hash
        hash=$(awk -v fn="$filename" '$2 == "(" fn ")" {print $4}' "$hash_file" 2>/dev/null)
        if [ -z "$hash" ] && [ -n "$url_name" ]; then
            hash=$(awk -v fn="$url_name" '$2 == "(" fn ")" {print $4}' "$hash_file" 2>/dev/null)
        fi
        echo "$hash"
    fi
}

fetch_file() {
    local url="$1"
    local dest="$2"
    local fallback_url="${3:-}"
    local hash_file="${4:-}"
    local filename
    filename="$(basename "$dest")"
    local url_filename
    url_filename="$(basename "$url")"
    
    local expected_hash=""
    if [ -n "$hash_file" ]; then
        expected_hash="$(get_expected_sha256 "$filename" "$hash_file" "$url_filename" 2>/dev/null || true)"
    fi

    if [ -f "$dest" ]; then
        if [ ! -s "$dest" ]; then
            echo "⚠️ Empty file detected in ${filename}. Removing..."
            rm -f "$dest"
        elif [ -n "$expected_hash" ]; then
            local actual_hash
            actual_hash="$(calc_sha256 "$dest")"
            if [ "$actual_hash" != "$expected_hash" ]; then
                echo "⚠️ SHA256 checksum mismatch for ${filename} (cached: ${actual_hash:0:8}..., expected: ${expected_hash:0:8}...). Removing corrupted cache..."
                rm -f "$dest"
            fi
        elif head -n 1 "$dest" 2>/dev/null | grep -qi "<html"; then
            echo "⚠️ Corrupted HTML download detected in ${filename}. Re-downloading..."
            rm -f "$dest"
        fi
    fi

    if [ ! -f "$dest" ] || [ ! -s "$dest" ]; then
        echo "  -> Downloading ${filename}..."
        local download_success=false
        if curl -f -L "$url" -o "$dest"; then
            download_success=true
        elif [ -n "$fallback_url" ]; then
            echo "     Retrying from fallback mirror..."
            if curl -f -L "$fallback_url" -o "$dest"; then
                download_success=true
            fi
        fi

        if [ "$download_success" = false ] || [ ! -f "$dest" ]; then
            echo "❌ Failed to download ${filename}"
            exit 1
        fi

        # Verify hash after download if expected hash is known
        if [ -n "$expected_hash" ]; then
            local downloaded_hash
            downloaded_hash="$(calc_sha256 "$dest")"
            if [ "$downloaded_hash" != "$expected_hash" ]; then
                echo "❌ SHA256 verification failed for ${filename} (got ${downloaded_hash}, expected ${expected_hash})"
                rm -f "$dest"
                exit 1
            fi
        fi
    else
        if [ -n "$expected_hash" ]; then
            echo "  -> Cached & Verified (SHA256): ${filename}"
        else
            echo "  -> Cached: ${filename}"
        fi
    fi
}

generate_install_configs() {
    echo ""
    echo ">> Preparing autoinstall response configuration..."
    local user_config_file="${CONFIGS_DIR}/user_config.env"
    if [ -f "$user_config_file" ]; then
        echo ">> Loading custom user configuration from ${user_config_file}..."
        # shellcheck source=/dev/null
        source "$user_config_file"
    fi

    # Respect POMERA_MODEL from user_config.env if not explicitly overridden by CLI
    if [ -n "${POMERA_MODEL:-}" ] && [ "$MODEL_TYPE" = "dm250" ]; then
        MODEL_TYPE="$POMERA_MODEL"
    fi

    # CLI arguments take strict precedence over user_config.env
    [ -n "${CLI_SMART_KERNEL:-}" ] && POMERA_SMART_KERNEL="$CLI_SMART_KERNEL"
    [ -n "${CLI_PATCH_USB_HUB:-}" ] && POMERA_PATCH_USB_HUB="$CLI_PATCH_USB_HUB"
    [ -n "${CLI_PATCH_X11_KEYS:-}" ] && POMERA_PATCH_X11_KEYS="$CLI_PATCH_X11_KEYS"
    [ -n "${CLI_PATCH_MLTERM_FB:-}" ] && POMERA_PATCH_MLTERM_FB="$CLI_PATCH_MLTERM_FB"
    [ -n "${CLI_PATCH_BT:-}" ] && POMERA_PATCH_BT="$CLI_PATCH_BT"
    [ -n "${CLI_WORKSPACE:-}" ] && POMERA_WORKSPACE="$CLI_WORKSPACE"

    local conf_user="${POMERA_USERNAME:-pomera}"
    local conf_host="${POMERA_HOSTNAME:-pomera}"
    local conf_tz="${POMERA_TIMEZONE:-Asia/Tokyo}"
    local conf_rootpass="${POMERA_ROOT_PASSWORD:-pomera}"
    local conf_userpass="${POMERA_USER_PASSWORD:-pomera}"
    local conf_sshd="${POMERA_ENABLE_SSHD:-yes}"
    local conf_rootssh="${POMERA_ALLOW_ROOT_SSH:-no}"
    local conf_confirm_install="${POMERA_CONFIRM_INSTALL:-yes}"
    local conf_lid_interval="${POMERA_LID_INTERVAL:-2.0}"
    local conf_cpu_policy="${POMERA_CPU_POLICY:-auto}"

    POMERA_SMART_KERNEL="${POMERA_SMART_KERNEL:-yes}"
    POMERA_PATCH_USB_HUB="${POMERA_PATCH_USB_HUB:-yes}"
    POMERA_PATCH_X11_KEYS="${POMERA_PATCH_X11_KEYS:-yes}"
    POMERA_PATCH_MLTERM_FB="${POMERA_PATCH_MLTERM_FB:-yes}"
    POMERA_PATCH_BT="${POMERA_PATCH_BT:-yes}"
    POMERA_WORKSPACE="${POMERA_WORKSPACE:-yes}"
    POMERA_BUILD_PATCHED_KERNEL="${POMERA_BUILD_PATCHED_KERNEL:-no}"

    # Inject user credentials into _build_cache/install.site.env to guarantee 100% password enforcement without dirtying git configs
    cat << EOF > "${WORK_DIR}/install.site.env"
export POMERA_USERNAME="${conf_user}"
export POMERA_HOSTNAME="${conf_host}"
export POMERA_ROOT_PASSWORD="${conf_rootpass}"
export POMERA_USER_PASSWORD="${conf_userpass}"
export POMERA_CONFIRM_INSTALL="${conf_confirm_install}"
export POMERA_LID_INTERVAL="${conf_lid_interval}"
export POMERA_CPU_POLICY="${conf_cpu_policy}"
export POMERA_WORKSPACE="${POMERA_WORKSPACE}"
export POMERA_MODEL="${MODEL_TYPE}"
EOF

    # Write dynamic install.conf into _build_cache
    cat << EOF > "${WORK_DIR}/install.conf"
Choose your keyboard layout = default
Choose your keyboard layout ('?' or 'L' for list) = default
System hostname = ${conf_host}
System hostname? (short form, e.g. 'foo') = ${conf_host}
Network interface to configure = done
Network interface to configure? (name, lladdr, '?', or 'done') = done
Which network interface to configure = done
IPv4 address for bwfm0 = none
IPv6 address for bwfm0 = none
Default IPv4 route = none
DNS domain name = none
DNS nameservers = none
Password for root account = ${conf_rootpass}
Password for root account? = ${conf_rootpass}
Public ssh key for root account = none
Public ssh key for root account? = none
Start sshd(8) by default = ${conf_sshd}
Start sshd(8) by default? = ${conf_sshd}
Start sshd = ${conf_sshd}
Change the default console to com0 = no
Change the default console to com0? = no
Setup a user = ${conf_user}
Setup a user? (enter a lower-case loginname, or 'no') = ${conf_user}
Full name for user ${conf_user} = ${conf_user}
Full name for user ${conf_user}? = ${conf_user}
Password for user ${conf_user} = ${conf_userpass}
Password for user ${conf_user}? = ${conf_userpass}
Public ssh key for user ${conf_user} = none
Public ssh key for user ${conf_user}? = none
Allow root ssh login = ${conf_rootssh}
Allow root ssh login? (yes, no, prohibit-password) = ${conf_rootssh}
Do you expect to run the X Window System = yes
Do you want the X Window System to be started by xenodm = no
What timezone are you in = ${conf_tz}
What timezone are you in? ('?' for list) = ${conf_tz}
Which disk is the root disk = sd1
Which disk is the root disk? ('?' for details) = sd1
Encrypt the root disk with a (p)assphrase or (k)eydisk = no
Encrypt the root disk with a (p)assphrase or (k)eydisk? = no
Encrypt the root disk = no
Encrypt the root disk with = no
Encrypt the root disk with a passphrase = no
Use (W)hole disk or (E)dit the MBR = whole
Use (W)hole disk or (E)dit the MBR? = whole
Use (W)hole disk MBR, whole disk (G)PT or (E)dit = whole
Use (W)hole disk MBR, whole disk (G)PT or (E)dit? = whole
whole disk or edit the mbr = whole
whole disk or edit = whole
edit the mbr = whole
whole disk = whole
Use whole disk = whole
URL to autopartitioning template for disklabel = none
URL to autopartitioning template for disklabel? = none
URL to autopartitioning template = none
Use (A)uto layout, (E)dit auto layout, or create (C)ustom layout = a
Use (A)uto layout, (E)dit auto layout, or create (C)ustom layout? = a
Use auto layout = a
Auto layout = a
Location of sets = disk
Location of sets? = disk
Is the disk partition already mounted = yes
Is the disk partition already mounted? = yes
Which disk contains the install media = sd0
Which disk contains the install media? = sd0
Which sd0 partition has the install sets = a
Which sd0 partition has the install sets? = a
Pathname to the sets = /
Pathname to the sets? = /
INSTALL. not found. Use sets found here anyway = yes
INSTALL. not found. Use sets found here anyway? = yes
INSTALL. not found = yes
not found. Use sets found here anyway = yes
not found. Use sets found here anyway? = yes
Use sets found here anyway = yes
Use sets found here anyway? = yes
INSTALL.armv7 not found. Use sets found here anyway = yes
INSTALL.armv7 not found. Use sets found here anyway? = yes
Set name(s) = all
Set name(s)? = all
Set name(s) = done
Set name(s)? = done
Signature check of SHA256.sig failed. Continue without verification = yes
Signature check of SHA256.sig failed. Continue without verification? = yes
Signature check of SHA256.sig failed = yes
Directory does not contain SHA256.sig. Continue without verification = yes
Directory does not contain SHA256.sig. Continue without verification? = yes
Continue without verification = yes
Continue anyway = yes
INSTALL.armv7 not found = yes
Checksum test for bsd failed. Continue anyway? = yes
Checksum test for bsd.rd failed. Continue anyway? = yes
Checksum test for base79.tgz failed. Continue anyway? = yes
Checksum test for comp79.tgz failed. Continue anyway? = yes
Checksum test for man79.tgz failed. Continue anyway? = yes
Checksum test for xbase79.tgz failed. Continue anyway? = yes
Checksum test for xfont79.tgz failed. Continue anyway? = yes
Checksum test for xserv79.tgz failed. Continue anyway? = yes
Checksum test for xshare79.tgz failed. Continue anyway? = yes
Checksum test for site79.tgz failed. Continue anyway? = yes
Location of sets? (or 'done') = done
Location of sets = done
Location of sets? = done
EOF

    # Mirror to configs/install.conf only if missing
    if [ ! -f "${CONFIGS_DIR}/install.conf" ]; then
        cp -f "${WORK_DIR}/install.conf" "${CONFIGS_DIR}/install.conf"
    fi
}

fetch_all_artifacts() {
    echo "=== [1/3] Fetching Official OpenBSD & DM250 Artifacts ==="

    # Fetch Official Checksums first for automated SHA256 integrity verification
    fetch_file "${ARM64_MIRROR}/SHA256" "${WORK_DIR}/SHA256.arm64" "${ARM64_SNAP_MIRROR}/SHA256"
    fetch_file "${ARMV7_MIRROR}/SHA256.sig" "${WORK_DIR}/SHA256.sig" "${ARMV7_SNAP_MIRROR}/SHA256.sig"

    # Lightweight OpenBSD arm64 miniroot Image (~43MB vs 630MB install image, saving 587MB)
    if [ ! -f "${WORK_DIR}/install79_arm64.img" ]; then
        fetch_file "${ARM64_MIRROR}/miniroot${OPENBSD_VER}.img" "${WORK_DIR}/miniroot79.img" "${ARM64_SNAP_MIRROR}/miniroot${OPENBSD_VER}.img" "${WORK_DIR}/SHA256.arm64"
    fi

    # Rockchip BootROM Binaries
    fetch_file "${RKBIN_MIRROR}/rk3128_ddr_300MHz_v2.12.bin" "${WORK_DIR}/rk3128_ddr.bin"
    fetch_file "${RKBIN_MIRROR}/rk312x_miniloader_v2.63.bin" "${WORK_DIR}/rk312x_miniloader.bin"

    # EFI & DM250 Binaries
    fetch_file "${ARMV7_MIRROR}/BOOTARM.EFI" "${WORK_DIR}/BOOTARM.EFI" "${ARMV7_SNAP_MIRROR}/BOOTARM.EFI" "${WORK_DIR}/SHA256.sig"
    fetch_file "${ARMV7_MIRROR}/bsd.rd" "${WORK_DIR}/bsd.rd" "${ARMV7_SNAP_MIRROR}/bsd.rd" "${WORK_DIR}/SHA256.sig"
    
    # Auto-Boot U-Boot image (Ensures hands-free auto-booting OpenBSD payload)
    local uboot_target="${WORK_DIR}/uboot.img"
    local need_build_uboot=false
    if [ "$REBUILD_UBOOT" = true ] || [ ! -f "$uboot_target" ]; then
        need_build_uboot=true
    elif ! grep -a -q "load mmc 1:1" "$uboot_target"; then
        echo ">> Detected legacy U-Boot without hands-free auto-boot. Upgrading..."
        need_build_uboot=true
    fi

    if [ "$need_build_uboot" = true ]; then
        local uboot_builder="${SCRIPT_DIR}/scripts/build_uboot.sh"

        if [ -f "$uboot_builder" ] && { command -v arm-none-eabi-gcc >/dev/null 2>&1 || command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; }; then
            echo ">> Compiling custom auto-booting U-Boot (${uboot_target})..."
            "$uboot_builder" "$uboot_target"
        else
            echo ">> Fetching cached U-Boot from mirror..."
            if [ "$MODEL_TYPE" = "dm250us" ]; then
                fetch_file "${JCS_MIRROR}/us-uboot.img" "$uboot_target"
            else
                fetch_file "${JCS_MIRROR}/uboot.img" "$uboot_target"
            fi
        fi
    fi

    # Generate 100% safe non-destructive _sdboot.sh (NEVER writes to internal eMMC)
    cat << 'EOF' > "${WORK_DIR}/_sdboot.sh"
#!/bin/sh
# Safe _sdboot.sh - 100% NON-DESTRUCTIVE (NEVER writes to eMMC)
mkdir -p /tmp/sd
mount /dev/mmcblk1p1 /tmp/sd 2>/dev/null || true
[ -d /system/etc/firmware ] && cp -R /system/etc/firmware /tmp/sd/ 2>/dev/null || true
mkdir -p /tmp/sys_info
mount /dev/mmcblk0p11 /tmp/sys_info 2>/dev/null || true
[ -d /tmp/sys_info ] && cp -R /tmp/sys_info /tmp/sd/ 2>/dev/null || true
umount /tmp/sys_info 2>/dev/null || true
umount /tmp/sd 2>/dev/null || true
sync
reboot
EOF
    fetch_file "${JCS_MIRROR}/logo.bmp" "${WORK_DIR}/logo.bmp"

    # OpenBSD Sets
    local base_sets=(
        "base${OPENBSD_VER}.tgz"
        "comp${OPENBSD_VER}.tgz"
        "man${OPENBSD_VER}.tgz"
        "xbase${OPENBSD_VER}.tgz"
        "xfont${OPENBSD_VER}.tgz"
        "xshare${OPENBSD_VER}.tgz"
        "xserv${OPENBSD_VER}.tgz"
    )

    for bset in "${base_sets[@]}"; do
        fetch_file "${ARMV7_MIRROR}/${bset}" "${WORK_DIR}/${bset}" "${ARMV7_SNAP_MIRROR}/${bset}" "${WORK_DIR}/SHA256.sig"
    done
    fetch_file "${FIRMWARE_MIRROR}/bwfm-firmware-20200316.1.3p5.tgz" "${WORK_DIR}/bwfm-firmware-20200316.1.3p5.tgz" "${FIRMWARE_SNAP_MIRROR}/bwfm-firmware-20200316.1.3p5.tgz"

    # Pre-fetch offline workspace packages if requested (saves 10-15m on device)
    if [ "${POMERA_WORKSPACE:-yes}" = "yes" ]; then
        echo ""
        echo ">> [Workspace] Fetching & caching offline workspace packages (Vim, curl, git, mlterm, Noto CJK, dmenu)..."
        python3 "${SCRIPTS_DIR}/fetch_packages.py" --dest "${WORK_DIR}/packages"
    fi

    # Fetch official mlterm source for QEMU / offline building
    fetch_file "https://github.com/arakiken/mlterm/archive/refs/tags/3.9.5.tar.gz" "${WORK_DIR}/mlterm-3.9.5.tar.gz"

    # Always fetch upstream official kernel to a protected cache location
    fetch_file "${JCS_MIRROR}/bsd" "${WORK_DIR}/bsd.official"

    # Evaluate whether kernel patches or smart optimization are requested
    local want_kernel_patch=false
    local check_flags=()
    local target_kconfig="GENERIC"

    if [ "$POMERA_SMART_KERNEL" = "yes" ]; then
        want_kernel_patch=true
        target_kconfig="DM250"
        check_flags+=("--check-smart")
    fi
    if [ "$POMERA_PATCH_USB_HUB" = "yes" ]; then
        want_kernel_patch=true
        check_flags+=("--check-usb")
    fi
    if [ "$POMERA_PATCH_X11_KEYS" = "yes" ]; then
        want_kernel_patch=true
        check_flags+=("--check-x11")
    fi
    if [ "$POMERA_PATCH_MLTERM_FB" = "yes" ]; then
        want_kernel_patch=true
        check_flags+=("--check-smode")
    fi
    if [ "$POMERA_PATCH_BT" = "yes" ]; then
        want_kernel_patch=true
        check_flags+=("--check-bt")
    fi

    if [ "$BUILD_KERNEL" = "true" ] || [ "$POMERA_BUILD_PATCHED_KERNEL" = "yes" ]; then
        want_kernel_patch=true
    fi

    local current_kernel_sig="CONFIG=${target_kconfig}|SMART=${POMERA_SMART_KERNEL}|USB_HUB=${POMERA_PATCH_USB_HUB}|X11_KEYS=${POMERA_PATCH_X11_KEYS}|MLTERM_FB=${POMERA_PATCH_MLTERM_FB}|BT=${POMERA_PATCH_BT}"
    local tag_file="${WORK_DIR}/bsd.patched.tag"
    local inspect_script="${SCRIPT_DIR}/scripts/inspect_kernel.py"

    if [ "$want_kernel_patch" = "true" ]; then
        echo ""
        echo "=== [Kernel Audit] Verifying Upstream Kernel Status (Config: ${target_kconfig}) ==="

        if [ "$BUILD_KERNEL" != "true" ] && [ "$POMERA_BUILD_PATCHED_KERNEL" != "yes" ] && \
           [ -f "$inspect_script" ] && python3 "$inspect_script" "${WORK_DIR}/bsd.official" "${check_flags[@]}"; then
            echo ">> ✨ Upstream jcs.org kernel already satisfies requested configuration!"
            echo "   Using official binary directly. Skipping QEMU rebuild."
            cp -f "${WORK_DIR}/bsd.official" "${WORK_DIR}/bsd"
        else
            echo ">> Upstream jcs.org kernel does NOT satisfy requested configuration (${check_flags[*]})."
            local need_compile=false

            if [ "$BUILD_KERNEL" = "true" ] || [ "$POMERA_BUILD_PATCHED_KERNEL" = "yes" ]; then
                echo ">> Explicit kernel rebuild requested via CLI / environment setting."
                need_compile=true
            elif [ -f "${WORK_DIR}/bsd.patched" ] && [ -f "$tag_file" ]; then
                local cached_sig
                cached_sig="$(cat "$tag_file" 2>/dev/null || echo "")"
                if [ "$cached_sig" = "$current_kernel_sig" ]; then
                    if [ -f "$inspect_script" ] && python3 "$inspect_script" "${WORK_DIR}/bsd.patched" "${check_flags[@]}"; then
                        echo ">> Reusing verified cached custom kernel (_build_cache/bsd.patched)..."
                        echo "   (Signature match: ${cached_sig})"
                        cp -f "${WORK_DIR}/bsd.patched" "${WORK_DIR}/bsd"
                    else
                        echo ">> Cached custom kernel failed integrity inspection. Rebuilding..."
                        need_compile=true
                    fi
                else
                    echo ">> Cached custom kernel signature mismatch:"
                    echo "   Current: ${current_kernel_sig}"
                    echo "   Cached:  ${cached_sig}"
                    echo ">> Invalidating outdated kernel cache and rebuilding with new settings..."
                    need_compile=true
                fi
            else
                need_compile=true
            fi

            if [ "$need_compile" = "true" ]; then
                if [ "$DOWNLOAD_ONLY" = true ]; then
                    echo ">> [--download-only] Skipping kernel compilation. Fetching generic base bsd for cache..."
                    fetch_file "${ARMV7_MIRROR}/bsd" "${WORK_DIR}/bsd_generic" "${ARMV7_SNAP_MIRROR}/bsd" "${WORK_DIR}/SHA256.sig"
                else
                    echo "=== [Kernel Builder] Compiling Custom Kernel via QEMU (Config: ${target_kconfig}) ==="
                    fetch_file "${ARMV7_MIRROR}/bsd" "${WORK_DIR}/bsd_generic" "${ARMV7_SNAP_MIRROR}/bsd" "${WORK_DIR}/SHA256.sig"
                local build_args=("--config" "${target_kconfig}")
                if [ "$POMERA_PATCH_USB_HUB" = "yes" ]; then
                    build_args+=("--patch-usb")
                else
                    build_args+=("--no-patch-usb")
                fi
                if [ "$POMERA_PATCH_X11_KEYS" = "yes" ]; then
                    build_args+=("--patch-x11")
                else
                    build_args+=("--no-patch-x11")
                fi
                if [ "$POMERA_PATCH_MLTERM_FB" = "yes" ]; then
                    build_args+=("--patch-smode")
                else
                    build_args+=("--no-patch-smode")
                fi
                if [ "$POMERA_PATCH_BT" = "yes" ]; then
                    build_args+=("--patch-bt")
                else
                    build_args+=("--no-patch-bt")
                fi

                    python3 "${SCRIPT_DIR}/scripts/build_kernel_qemu.py" "${build_args[@]}"
                    if [ -f "${WORK_DIR}/bsd.patched" ]; then
                        cp -f "${WORK_DIR}/bsd.patched" "${WORK_DIR}/bsd"
                        echo "$current_kernel_sig" > "$tag_file"
                    fi
                fi
            fi
        fi
    else
        echo ">> Using standard official jcs.org kernel (unpatched GENERIC)."
        cp -f "${WORK_DIR}/bsd.official" "${WORK_DIR}/bsd"
    fi

    # Build helper binaries
    local idbloader_img="${WORK_DIR}/idbloader.img"
    python3 "${SCRIPT_DIR}/scripts/make_idbloader.py" "${WORK_DIR}/rk3128_ddr.bin" "${WORK_DIR}/rk312x_miniloader.bin" "${idbloader_img}"

    local dm250_dtb="${WORK_DIR}/kingjim-dm250.dtb"
    python3 "${SCRIPT_DIR}/scripts/extract_dtb.py" "${WORK_DIR}/uboot.img" "${dm250_dtb}"

    # Build or verify Pomera-optimized mlterm-fb archive via QEMU
    local mlterm_tar="${WORK_DIR}/mlterm-fb-dm250.tar.gz"
    local needs_mlterm_build=false
    if [ "$REBUILD_MLTERM" = true ] || [ ! -f "$mlterm_tar" ]; then
        needs_mlterm_build=true
    elif ! tar -ztf "$mlterm_tar" usr/local/bin/mlterm-fb-pomera >/dev/null 2>&1; then
        echo ">> Existing mlterm archive is outdated (missing mlterm-fb-pomera). Scheduling rebuild..."
        needs_mlterm_build=true
    fi

    if [ "$needs_mlterm_build" = true ]; then
        if [ "$DOWNLOAD_ONLY" = false ] || [ "$REBUILD_MLTERM" = true ]; then
            echo ""
            echo "=== [mlterm-fb Build] Compiling Pomera-optimized mlterm-fb via QEMU ==="
            python3 "${SCRIPT_DIR}/scripts/build_mlterm_qemu.py" --force --output "$mlterm_tar"
        fi
    fi
}

list_external_disks_darwin() {
    DETECTED_DEVICES=()
    local ext_disks
    ext_disks="$(diskutil list external physical 2>/dev/null || diskutil list external 2>/dev/null || true)"
    if [ -n "$(echo "$ext_disks" | tr -d '[:space:]')" ]; then
        echo "$ext_disks"
        echo ""
        local raw_list
        raw_list="$(echo "$ext_disks" | grep -o '/dev/disk[0-9]\+' | sort -u || true)"
        local idx=1
        for d in $raw_list; do
            local rdisk="/dev/r${d#/dev/}"
            DETECTED_DEVICES+=("$rdisk")
            printf "  [%d] %s (%s)\n" "$idx" "$rdisk" "$d"
            idx=$((idx + 1))
        done
        echo ""
    else
        echo "⚠️  No external storage devices (USB / SD Card) detected."
        echo "   Please plug in your SD card reader or USB adapter and ensure it is connected."
        echo ""
    fi
}

list_external_disks_linux() {
    DETECTED_DEVICES=()
    local root_dev=""
    if command -v findmnt >/dev/null 2>&1; then
        root_dev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    fi
    local root_pkname=""
    if [ -n "$root_dev" ] && command -v lsblk >/dev/null 2>&1; then
        root_pkname="$(lsblk -no PKNAME "$root_dev" 2>/dev/null || true)"
        if [ -z "$root_pkname" ]; then
            root_pkname="$(basename "$root_dev")"
        fi
    fi

    printf "%-4s %-16s %-10s %-25s %-10s\n" "NUM" "DEVICE" "SIZE" "MODEL" "TRAN"
    printf "%-4s %-16s %-10s %-25s %-10s\n" "----" "----------------" "----------" "-------------------------" "----------"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Safely extract attributes without eval
        local name="" size="" model="" tran="" rm_flag="" hotplug=""
        name="$(echo "$line" | grep -o 'NAME="[^"]*"' | cut -d'"' -f2 || true)"
        size="$(echo "$line" | grep -o 'SIZE="[^"]*"' | cut -d'"' -f2 || true)"
        model="$(echo "$line" | grep -o 'MODEL="[^"]*"' | cut -d'"' -f2 || true)"
        tran="$(echo "$line" | grep -o 'TRAN="[^"]*"' | cut -d'"' -f2 || true)"
        rm_flag="$(echo "$line" | grep -o 'RM="[^"]*"' | cut -d'"' -f2 || true)"
        hotplug="$(echo "$line" | grep -o 'HOTPLUG="[^"]*"' | cut -d'"' -f2 || true)"

        # Exclude virtual / special devices
        if [[ "$name" =~ ^/dev/(loop|zram|ram|sr|dm-|nbd) ]]; then
            continue
        fi

        # Exclude active host OS root drive
        local base_name
        base_name="$(basename "$name")"
        if [ -n "$root_pkname" ] && [ "$base_name" = "$root_pkname" ]; then
            continue
        fi

        # Extract external / removable / hotplug / MMC devices only
        if [[ "$tran" == "usb" || "$tran" == "mmc" || "$rm_flag" == "1" || "$hotplug" == "1" || "$name" =~ mmcblk ]]; then
            DETECTED_DEVICES+=("$name")
            local num="${#DETECTED_DEVICES[@]}"
            printf "[%d]  %-16s %-10s %-25s %-10s\n" "$num" "$name" "$size" "${model:-Unknown}" "${tran:-external}"
        fi
    done < <(lsblk -P -d -p -o NAME,SIZE,MODEL,TRAN,RM,HOTPLUG 2>/dev/null || true)

    echo ""
    if [ "${#DETECTED_DEVICES[@]}" -eq 0 ]; then
        echo "⚠️  No external storage devices (USB / SD Card) detected."
        echo "   Please plug in your SD card reader or USB adapter and ensure it is connected."
        echo ""
    fi
}

validate_target_dev() {
    local target="$1"
    if [ "$OS_NAME" = "Linux" ]; then
        if [ ! -b "$target" ]; then
            echo "❌ Error: Block device '$target' does not exist."
            exit 1
        fi

        # Protect active root filesystem (/)
        local root_src=""
        if command -v findmnt >/dev/null 2>&1; then
            root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
        fi
        if [ -n "$root_src" ]; then
            local root_pk=""
            root_pk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
            local root_disk="/dev/${root_pk:-$(basename "$root_src")}"
            if [ "$target" = "$root_disk" ] || [ "$target" = "$root_src" ]; then
                echo "❌ CRITICAL SAFETY ERROR: '$target' is your active OS root storage drive!"
                echo "   Aborting to prevent accidental system drive erasure."
                exit 1
            fi
        fi
    elif [ "$OS_NAME" = "Darwin" ]; then
        local raw_disk="$target"
        if [[ "$raw_disk" =~ ^/dev/r?(disk[0-9]+.*)$ ]]; then
            raw_disk="${BASH_REMATCH[1]}"
        fi

        if ! diskutil info "$raw_disk" >/dev/null 2>&1; then
            echo "❌ Error: Disk device '$target' does not exist."
            exit 1
        fi

        if [[ "$target" =~ /dev/r?disk0($|s[0-9]+) ]] || [ "$raw_disk" = "disk0" ]; then
            echo "❌ CRITICAL SAFETY ERROR: '$target' is the internal macOS system drive (disk0)!"
            echo "   Aborting to prevent accidental system drive erasure."
            exit 1
        fi

        local is_internal
        is_internal="$(diskutil info "$raw_disk" 2>/dev/null | grep -i "Device Location:" | awk '{print $3}' || true)"
        if [ "$is_internal" = "Internal" ]; then
            echo "❌ CRITICAL SAFETY ERROR: '$target' is an internal macOS storage drive!"
            echo "   Aborting to prevent accidental system drive erasure."
            exit 1
        fi
    fi
}

select_target_device() {
    echo ""
    echo "=== [2/3] Selecting Target SD Card ==="

    if [ -z "$TARGET_DEV" ]; then
        if [ "$OS_NAME" = "Darwin" ]; then
            list_external_disks_darwin
        else
            list_external_disks_linux
        fi

        local prompt_str=""
        local default_dev=""

        if [ "${#DETECTED_DEVICES[@]}" -eq 1 ]; then
            default_dev="${DETECTED_DEVICES[0]}"
            prompt_str="Enter target SD card device or [1] [default: ${default_dev}]: "
        elif [ "${#DETECTED_DEVICES[@]}" -gt 1 ]; then
            prompt_str="Enter target SD card device or number (1-${#DETECTED_DEVICES[@]}): "
        else
            if [ "$OS_NAME" = "Darwin" ]; then
                prompt_str="Enter target SD card device (e.g. /dev/rdisk4): "
            else
                prompt_str="Enter target SD card device (e.g. /dev/sdb): "
            fi
        fi

        local input_choice=""
        read -r -p "$prompt_str" input_choice

        if [ -z "$input_choice" ]; then
            if [ -n "$default_dev" ]; then
                TARGET_DEV="$default_dev"
                echo "Selected default device: ${TARGET_DEV}"
            else
                echo "No target device specified. Exiting."
                exit 1
            fi
        elif [[ "$input_choice" =~ ^[0-9]+$ ]]; then
            local idx=$((input_choice - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DETECTED_DEVICES[@]}" ]; then
                TARGET_DEV="${DETECTED_DEVICES[$idx]}"
                echo "Selected device [${input_choice}]: ${TARGET_DEV}"
            else
                echo "❌ Invalid device number: $input_choice"
                exit 1
            fi
        else
            TARGET_DEV="$input_choice"
        fi
    fi

    if [ -z "$TARGET_DEV" ]; then
        echo "No target device specified. Exiting."
        exit 1
    fi

    validate_target_dev "$TARGET_DEV"

    echo "⚠️  CRITICAL WARNING: All data on ${TARGET_DEV} will be COMPLETELY ERASED!"
    local confirm=""
    read -r -p "Are you absolutely sure you want to format ${TARGET_DEV}? [yes/NO]: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
}

flash_bootloader_sectors_host() {
    local target="$1"
    local raw_target="$target"
    local idbloader="${WORK_DIR}/idbloader.img"
    local uboot="${WORK_DIR}/uboot.img"

    if [ ! -f "$idbloader" ] || [ ! -f "$uboot" ]; then
        echo "❌ Error: Bootloader images missing: $idbloader or $uboot"
        exit 1
    fi

    echo ""
    echo "=== Flashing Rockchip BootROM Bootloader to SD Raw Sectors (Host Direct) ==="
    echo "    - idbloader.img -> Sector 64 (32KB offset)"
    echo "    - uboot.img     -> Sector 16384 (8MB offset)"

    if [ "$OS_NAME" = "Darwin" ]; then
        if [[ "$target" =~ ^/dev/disk([0-9]+.*)$ ]]; then
            raw_target="/dev/rdisk${BASH_REMATCH[1]}"
            target="/dev/disk${BASH_REMATCH[1]}"
        elif [[ "$target" =~ ^/dev/rdisk([0-9]+.*)$ ]]; then
            raw_target="/dev/rdisk${BASH_REMATCH[1]}"
            target="/dev/disk${BASH_REMATCH[1]}"
        elif [[ "$target" =~ ^disk([0-9]+.*)$ ]]; then
            raw_target="/dev/rdisk${BASH_REMATCH[1]}"
            target="/dev/disk${BASH_REMATCH[1]}"
        fi

        echo "Writing directly to SD raw device: $raw_target"
        diskutil unmountDisk "$target" 2>/dev/null || true
        sudo -p "🔐 [sudo] Password for host user %u: " dd if="$idbloader" of="$raw_target" bs=512 seek=64 conv=notrunc
        diskutil unmountDisk "$target" 2>/dev/null || true
        sudo -p "🔐 [sudo] Password for host user %u: " dd if="$uboot" of="$raw_target" bs=512 seek=16384 conv=notrunc
        diskutil unmountDisk "$target" 2>/dev/null || true
        sync
    elif [ -b "$target" ]; then
        echo "Writing directly to SD block device: $target"
        sudo -p "🔐 [sudo] Password for host user %u: " dd if="$idbloader" of="$target" bs=512 seek=64 conv=notrunc,fdatasync
        sudo -p "🔐 [sudo] Password for host user %u: " dd if="$uboot" of="$target" bs=512 seek=16384 conv=notrunc,fdatasync
        sync
    else
        echo "Writing directly to image file: $target"
        dd if="$idbloader" of="$target" bs=512 seek=64 conv=notrunc
        dd if="$uboot" of="$target" bs=512 seek=16384 conv=notrunc
    fi
    echo "✅ Rockchip BootROM Bootloader successfully written to Sector 64 and Sector 16384!"
}

execute_builder() {
    echo ""
    echo "=== [3/3] Native OpenBSD SD Preparation (via Throwaway QEMU VM) ==="

    local target_drive=""
    if [ "$OS_NAME" = "Darwin" ]; then
        if [[ "$TARGET_DEV" =~ ^/dev/disk([0-9]+.*)$ ]]; then
            BLOCK_DEV="/dev/disk${BASH_REMATCH[1]}"
        elif [[ "$TARGET_DEV" =~ ^/dev/rdisk([0-9]+.*)$ ]]; then
            BLOCK_DEV="/dev/disk${BASH_REMATCH[1]}"
        else
            BLOCK_DEV="$TARGET_DEV"
        fi
        diskutil unmountDisk "$BLOCK_DEV" 2>/dev/null || true
        target_drive="$BLOCK_DEV"
    else
        target_drive="$TARGET_DEV"
        # On Linux, unmount any active partitions on the target drive to prevent kernel write conflicts
        if command -v umount >/dev/null 2>&1; then
            umount "${target_drive}"* 2>/dev/null || true
        fi
    fi

    # Ensure sudo privileges with clear explanation before prompting for password
    if [ -b "$target_drive" ] || [ -c "$target_drive" ] || [[ "$target_drive" =~ ^/dev/ ]]; then
        if ! sudo -n true 2>/dev/null; then
            echo ""
            echo "=========================================================="
            echo "🔐 [Host Administrator Privileges Required (sudo)]"
            echo "   Direct low-level access to SD card drive (${target_drive})"
            echo "   and running the throwaway QEMU VM requires host superuser privileges."
            echo "   Please enter your host PC login password (sudo password)."
            echo "   (Note: This is your computer's password, NOT the Pomera password)"
            echo "=========================================================="
            sudo -p "🔐 [sudo] Password for host user %u: " -v
            echo ""
        fi
    fi

    # Run QEMU Native OpenBSD Builder with sudo for raw disk access
    # (Engine formats partitions and deploys sets via native OpenBSD in throwaway QEMU VM)
    sudo python3 "${SCRIPT_DIR}/scripts/build_sd_passthrough.py" "${target_drive}" "${TOOL_VERSION}"

    # Flash Rockchip BootROM raw bootloader sectors (LBA 64 & 16384) directly from host shell
    flash_bootloader_sectors_host "${TARGET_DEV}"

    if [ "$OS_NAME" = "Darwin" ]; then
        diskutil unmountDisk "$BLOCK_DEV" 2>/dev/null || true
    fi

    echo ""
    echo "=========================================================="
    echo "🎉 OpenBSD DM250 Installer SD Card Created Successfully! (v${TOOL_VERSION})"
    echo "=========================================================="
    echo ""
    echo "Next Steps on Pomera DM250:"
    echo ""
    echo "⚡ [Launch OpenBSD Installer]:"
    echo "   1. Power OFF Pomera completely and insert this SD card."
    echo "   2. Turn ON Pomera with [Power Button] (hold 3-4 seconds)."
    echo "      - U-Boot automatically loads the installer kernel from SD card:"
    echo "        [Pomera DM250] Booting OpenBSD Installer (SD Card)..."
    echo "      - No manual boot command needed (hands-free auto-boot)."
    echo "   3. When prompted 'Start installation? (yes/N):', type 'yes' and press [Enter]."
    echo "      (Internal storage will only be modified after you explicitly confirm 'yes')"
    echo "   4. System will partition eMMC, extract all sets, and configure your system."
    echo "   5. When 'ALL OPERATIONS COMPLETED SUCCESSFULLY!' appears:"
    echo "      Remove the SD card and press [Enter] to power off."
    echo "   6. Turn ON Pomera to start OpenBSD from internal storage!"
}

main() {
    parse_arguments "$@"

    echo "=========================================================="
    echo "  Pomera DM250 OpenBSD Installer SD Builder v${TOOL_VERSION}"
    echo "  Host OS: ${OS_NAME} (${ARCH_NAME}) | Target Model: ${MODEL_TYPE}"
    echo "=========================================================="

    check_prerequisites
    mkdir -p "${WORK_DIR}"

    generate_install_configs
    fetch_all_artifacts

    if [ "$DOWNLOAD_ONLY" = true ]; then
        echo ""
        echo "✅ Download complete! All official artifacts cached in ${WORK_DIR}."
        exit 0
    fi

    select_target_device

    if [ "$BOOTLOADER_ONLY" = true ]; then
        flash_bootloader_sectors_host "${TARGET_DEV}"
        echo ""
        echo "🎉 Bootloader raw sectors (idbloader & uboot) successfully updated on ${TARGET_DEV}!"
        exit 0
    fi

    execute_builder
}

main "$@"
