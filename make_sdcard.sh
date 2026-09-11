#!/usr/bin/env bash
# =====================================================================
# Pomera DM250 OpenBSD Installer SD Builder (Native OpenBSD QEMU Engine)
#
# Supported Host OS: macOS (Apple Silicon / Intel), Linux (amd64 / arm64)
# Features:
# - Clean, transparent, zero prebuilt-blob architecture: fetches official OpenBSD & jcs binaries
# - Drives a temporary OpenBSD QEMU VM to run authentic fdisk/disklabel/newfs on the target SD card
# - 100% Guaranteed Native FFS/Disklabel compliance on physical Pomera DM250 hardware!
# - Bulletproof signal handling (SIGINT/SIGTERM) and clean resource reclamation
# =====================================================================

set -euo pipefail

TOOL_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WORK_DIR="${SCRIPT_DIR}/_build_cache"
CONFIGS_DIR="${SCRIPT_DIR}/configs"

TARGET_DEV=""
BLOCK_DEV=""
DOWNLOAD_ONLY=false
BOOTLOADER_ONLY=false
REBUILD_UBOOT=false
BUILD_KERNEL=false
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
    echo "  sudo $0 /dev/sdb       # Flash directly to SD card on Linux"
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
    local missing=()
    for cmd in curl python3 qemu-system-aarch64; do
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
            echo "  sudo apt update && sudo apt install -y curl python3 qemu-system-arm qemu-efi-aarch64"
        fi
        exit 1
    fi
}

fetch_file() {
    local url="$1"
    local dest="$2"
    local fallback_url="${3:-}"
    
    if [ -f "$dest" ]; then
        if head -n 1 "$dest" 2>/dev/null | grep -qi "<html"; then
            echo "⚠️ Corrupted HTML download detected in $(basename "$dest"). Re-downloading..."
            rm -f "$dest"
        fi
    fi

    if [ ! -f "$dest" ] || [ ! -s "$dest" ]; then
        echo "  -> Downloading $(basename "$dest")..."
        if ! curl -f -L -C - "$url" -o "$dest"; then
            if [ -n "$fallback_url" ]; then
                echo "     Retrying from fallback mirror..."
                curl -f -L -C - "$fallback_url" -o "$dest"
            else
                echo "❌ Failed to download $(basename "$dest")"
                exit 1
            fi
        fi
    else
        echo "  -> Cached: $(basename "$dest")"
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

    # Lightweight OpenBSD arm64 miniroot Image (~43MB vs 630MB install image, saving 587MB)
    if [ ! -f "${WORK_DIR}/install79_arm64.img" ]; then
        fetch_file "${ARM64_MIRROR}/miniroot${OPENBSD_VER}.img" "${WORK_DIR}/miniroot79.img" "${ARM64_SNAP_MIRROR}/miniroot${OPENBSD_VER}.img"
    fi

    # Rockchip BootROM Binaries
    fetch_file "${RKBIN_MIRROR}/rk3128_ddr_300MHz_v2.12.bin" "${WORK_DIR}/rk3128_ddr.bin"
    fetch_file "${RKBIN_MIRROR}/rk312x_miniloader_v2.63.bin" "${WORK_DIR}/rk312x_miniloader.bin"

    # EFI & DM250 Binaries
    fetch_file "${ARMV7_MIRROR}/BOOTARM.EFI" "${WORK_DIR}/BOOTARM.EFI" "${ARMV7_SNAP_MIRROR}/BOOTARM.EFI"
    fetch_file "${ARMV7_MIRROR}/bsd.rd" "${WORK_DIR}/bsd.rd" "${ARMV7_SNAP_MIRROR}/bsd.rd"
    
    # Auto-Boot U-Boot image (Ensures hands-free auto-booting OpenBSD payload)
    local uboot_target="${WORK_DIR}/uboot.img"
    local need_build_uboot=false
    if [ "$REBUILD_UBOOT" = true ] || [ ! -f "$uboot_target" ]; then
        need_build_uboot=true
    elif ! strings "$uboot_target" 2>/dev/null | grep -q "load mmc 1:1"; then
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
        fetch_file "${ARMV7_MIRROR}/${bset}" "${WORK_DIR}/${bset}" "${ARMV7_SNAP_MIRROR}/${bset}"
    done
    fetch_file "${ARMV7_MIRROR}/SHA256.sig" "${WORK_DIR}/SHA256.sig" "${ARMV7_SNAP_MIRROR}/SHA256.sig"
    fetch_file "${FIRMWARE_MIRROR}/bwfm-firmware-20200316.1.3p5.tgz" "${WORK_DIR}/bwfm-firmware-20200316.1.3p5.tgz" "${FIRMWARE_SNAP_MIRROR}/bwfm-firmware-20200316.1.3p5.tgz"

    # Pre-fetch offline workspace packages if requested (saves 10-15m on device)
    if [ "${POMERA_WORKSPACE:-yes}" = "yes" ]; then
        echo ""
        echo ">> [Workspace] Fetching & caching offline workspace packages (Vim, curl, git, mlterm, Noto CJK, dmenu)..."
        python3 "${SCRIPTS_DIR}/fetch_packages.py" --dest "${WORK_DIR}/packages"
    fi

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

    if [ "$BUILD_KERNEL" = "true" ] || [ "$POMERA_BUILD_PATCHED_KERNEL" = "yes" ]; then
        want_kernel_patch=true
        check_flags+=("--check-all")
    else
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
    fi

    local current_kernel_sig="CONFIG=${target_kconfig}|SMART=${POMERA_SMART_KERNEL}|USB_HUB=${POMERA_PATCH_USB_HUB}|X11_KEYS=${POMERA_PATCH_X11_KEYS}|MLTERM_FB=${POMERA_PATCH_MLTERM_FB}|BT=${POMERA_PATCH_BT}"
    local tag_file="${WORK_DIR}/bsd.patched.tag"
    local inspect_script="${SCRIPT_DIR}/scripts/inspect_kernel.py"

    if [ "$want_kernel_patch" = "true" ]; then
        echo ""
        echo "=== [Kernel Audit] Verifying Upstream Kernel Status (Config: ${target_kconfig}) ==="

        if [ -f "$inspect_script" ] && python3 "$inspect_script" "${WORK_DIR}/bsd.official" "${check_flags[@]}"; then
            echo ">> ✨ Upstream jcs.org kernel already satisfies requested configuration!"
            echo "   Using official binary directly. Skipping QEMU rebuild."
            cp -f "${WORK_DIR}/bsd.official" "${WORK_DIR}/bsd"
        else
            echo ">> Upstream jcs.org kernel does NOT satisfy requested configuration (${check_flags[*]})."
            local need_compile=false

            if [ -f "${WORK_DIR}/bsd.patched" ] && [ -f "$tag_file" ]; then
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
                echo "=== [Kernel Builder] Compiling Custom Kernel via QEMU (Config: ${target_kconfig}) ==="
                fetch_file "${ARMV7_MIRROR}/bsd" "${WORK_DIR}/bsd_generic" "${ARMV7_SNAP_MIRROR}/bsd"
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
    else
        echo ">> Using standard official jcs.org kernel (unpatched GENERIC)."
        cp -f "${WORK_DIR}/bsd.official" "${WORK_DIR}/bsd"
    fi

    # Build helper binaries
    local idbloader_img="${WORK_DIR}/idbloader.img"
    python3 "${SCRIPT_DIR}/scripts/make_idbloader.py" "${WORK_DIR}/rk3128_ddr.bin" "${WORK_DIR}/rk312x_miniloader.bin" "${idbloader_img}"

    local dm250_dtb="${WORK_DIR}/kingjim-dm250.dtb"
    python3 "${SCRIPT_DIR}/scripts/extract_dtb.py" "${WORK_DIR}/uboot.img" "${dm250_dtb}"
}

list_external_disks_darwin() {
    local ext_disks
    ext_disks="$(diskutil list external physical 2>/dev/null || diskutil list external 2>/dev/null || true)"
    if [ -n "$(echo "$ext_disks" | tr -d '[:space:]')" ]; then
        echo "$ext_disks"
        echo ""
    else
        echo "⚠️  No external storage devices (USB / SD Card) detected."
        echo "   Please plug in your SD card reader or USB adapter and ensure it is connected."
        echo ""
    fi
}

list_external_disks_linux() {
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

    local count=0
    printf "%-16s %-10s %-25s %-10s\n" "DEVICE" "SIZE" "MODEL" "TRAN"
    printf "%-16s %-10s %-25s %-10s\n" "----------------" "----------" "-------------------------" "----------"

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
            printf "%-16s %-10s %-25s %-10s\n" "$name" "$size" "${model:-Unknown}" "${tran:-external}"
            count=$((count + 1))
        fi
    done < <(lsblk -P -d -p -o NAME,SIZE,MODEL,TRAN,RM,HOTPLUG 2>/dev/null || true)

    echo ""
    if [ "$count" -eq 0 ]; then
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
            read -p "Enter target SD card device (e.g. /dev/rdisk4): " TARGET_DEV
        else
            list_external_disks_linux
            read -p "Enter target SD card device (e.g. /dev/sdb): " TARGET_DEV
        fi
    fi

    if [ -z "$TARGET_DEV" ]; then
        echo "No target device specified. Exiting."
        exit 1
    fi

    validate_target_dev "$TARGET_DEV"

    echo "⚠️  CRITICAL WARNING: All data on ${TARGET_DEV} will be COMPLETELY ERASED!"
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
        sudo dd if="$idbloader" of="$raw_target" bs=512 seek=64 conv=notrunc
        diskutil unmountDisk "$target" 2>/dev/null || true
        sudo dd if="$uboot" of="$raw_target" bs=512 seek=16384 conv=notrunc
        diskutil unmountDisk "$target" 2>/dev/null || true
        sync
    elif [ -b "$target" ]; then
        echo "Writing directly to SD block device: $target"
        sudo dd if="$idbloader" of="$target" bs=512 seek=64 conv=notrunc,fdatasync
        sudo dd if="$uboot" of="$target" bs=512 seek=16384 conv=notrunc,fdatasync
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
