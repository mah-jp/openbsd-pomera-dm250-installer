#!/usr/bin/env bash
# =====================================================================
# build_uboot.sh - Automated Builder for Pomera DM250 Auto-Booting U-Boot
#
# Builds custom U-Boot with automatic OpenBSD EFI boot command:
#   - Primary:   load mmc 1:1 0x62000000 efi/boot/bootarm.efi (SD card installer)
#   - Fallback:  load mmc 0:1 0x62000000 efi/boot/bootarm.efi (eMMC installed OS)
#   - Execution: bootefi 0x62000000
#
# Conforms to pomera-dm250-backup-restore-tool build standards.
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "${SCRIPT_DIR}/../../_build_cache" ] || [ -f "${SCRIPT_DIR}/../../make_sdcard.sh" ]; then
    BASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
else
    BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
WORK_DIR="${BASE_DIR}/_build_cache"
BUILD_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'pomera_uboot_build' || echo "/tmp/pomera_uboot_build_$$")
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT INT TERM
TARGET_ARG="${1:-${WORK_DIR}/uboot.img}"
# Ensure OUTPUT_IMG is absolute path
if [[ "$TARGET_ARG" = /* ]]; then
    OUTPUT_IMG="$TARGET_ARG"
else
    OUTPUT_IMG="${BASE_DIR}/${TARGET_ARG}"
fi

OS_NAME="$(uname -s)"
NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Determine ARM cross compiler
CROSS_COMPILE=""
for prefix in arm-none-eabi- arm-linux-gnueabihf- arm-linux-gnu- arm-none-linux-gnueabihf-; do
    if command -v "${prefix}gcc" >/dev/null 2>&1; then
        CROSS_COMPILE="$prefix"
        break
    fi
done

if [ -z "$CROSS_COMPILE" ]; then
    echo "❌ Error: No ARM cross-compiler found (arm-none-eabi-gcc or arm-linux-gnueabihf-gcc)." >&2
    echo "   On macOS, install with: brew install --cask gcc-arm-embedded" >&2
    echo "   On Linux, install with: sudo apt-get install gcc-arm-none-eabi" >&2
    exit 1
fi

# Tool dependencies
for cmd in curl dtc bison flex make python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Error: Required tool not found: $cmd" >&2
        exit 1
    fi
done

echo "=========================================================="
echo "  Pomera DM250 Auto-Boot U-Boot Builder"
echo "  Cross Compiler: ${CROSS_COMPILE}gcc"
echo "  Host OS: ${OS_NAME} | CPU Cores: ${NPROC}"
echo "=========================================================="

# macOS build environment adjustment
HOST_EXTRA_FLAGS=""
MAKE_CMD="make"
if [ "$OS_NAME" = "Darwin" ]; then
    export PATH="/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/bin:/usr/local/opt/make/libexec/gnubin:/usr/local/bin:$PATH"
    
    OPENSSL_DIR=$(brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null || true)
    if [ -z "$OPENSSL_DIR" ]; then
        for p in /opt/homebrew/opt/openssl@3 /opt/homebrew/opt/openssl /usr/local/opt/openssl@3 /usr/local/opt/openssl; do
            if [ -d "$p" ]; then OPENSSL_DIR="$p"; break; fi
        done
    fi
    
    EXTRA_INC=""
    EXTRA_LIB=""
    [ -n "$OPENSSL_DIR" ] && [ -d "$OPENSSL_DIR" ] && EXTRA_INC="-I${OPENSSL_DIR}/include" && EXTRA_LIB="-L${OPENSSL_DIR}/lib"
    
    if [ -n "$EXTRA_INC" ]; then
        export HOSTCFLAGS="$EXTRA_INC ${HOSTCFLAGS:-}"
        export HOSTLDFLAGS="$EXTRA_LIB ${HOSTLDFLAGS:-}"
        HOST_EXTRA_FLAGS="HOSTCFLAGS=\"$EXTRA_INC\" HOSTLDFLAGS=\"$EXTRA_LIB\""
    fi
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# 1. Download U-Boot source tree (pomera-dm250 branch)
UBOOT_TAR="${WORK_DIR}/u-boot-pomera-dm250.tar.gz"
if [ ! -d "u-boot" ]; then
    mkdir -p u-boot
    if [ ! -f "$UBOOT_TAR" ] || [ ! -s "$UBOOT_TAR" ]; then
        echo ">> [1/5] Downloading U-Boot source archive (pomera-dm250 branch)..."
        curl -sSL -f --retry 5 --retry-delay 3 https://github.com/jcs/u-boot/archive/refs/heads/pomera-dm250.tar.gz -o "$UBOOT_TAR"
    else
        echo ">> [1/5] Using cached U-Boot source archive: $(basename "$UBOOT_TAR")"
    fi
    tar -xzf "$UBOOT_TAR" -C u-boot --strip-components=1
fi

# 2. Download and compile Device Tree Blob
if [ ! -f "pomera-dm250.dtb" ]; then
    echo ">> [2/5] Downloading DTS sources and compiling Device Tree Blob..."
    mkdir -p dts
    DTS_CACHE_DIR="${WORK_DIR}/dts"
    mkdir -p "$DTS_CACHE_DIR"
    DTS_BASE_URL="https://raw.githubusercontent.com/jcs/linux-dm250/master/arch/arm/boot/dts/rockchip"
    DTS_FILES=(
        "pomera-dm250.dts"
        "pomera-dm250-kbd.dtsi"
        "pomera-dm250-lcd.dtsi"
        "pomera-dm250-led.dtsi"
        "pomera-dm250-mmc.dtsi"
        "pomera-dm250-power.dtsi"
        "pomera-dm250-usb.dtsi"
        "pomera-dm250-wifi.dtsi"
        "rk3128.dtsi"
    )
    for f in "${DTS_FILES[@]}"; do
        if [ -f "${DTS_CACHE_DIR}/$f" ] && [ -s "${DTS_CACHE_DIR}/$f" ]; then
            if head -n 1 "${DTS_CACHE_DIR}/$f" 2>/dev/null | grep -qi "<html"; then
                rm -f "${DTS_CACHE_DIR}/$f"
            fi
        fi

        if [ ! -f "${DTS_CACHE_DIR}/$f" ] || [ ! -s "${DTS_CACHE_DIR}/$f" ]; then
            echo "   -> Downloading $f..."
            curl -sSL --retry 5 --retry-delay 3 -f "$DTS_BASE_URL/$f" -o "${DTS_CACHE_DIR}/$f"
            sleep 2
        else
            echo "   -> Cached: $f"
        fi
        cp -f "${DTS_CACHE_DIR}/$f" "dts/$f"
    done
    
    "${CROSS_COMPILE}gcc" -E -P -x assembler-with-cpp -nostdinc \
        -I u-boot/include \
        -I u-boot/dts/upstream/include \
        -I dts \
        -undef -D__DTS__ dts/pomera-dm250.dts -o pomera-dm250.dts.preprocessed
    
    dtc -I dts -O dtb -o pomera-dm250.dtb pomera-dm250.dts.preprocessed
fi

# Copy DTB into U-Boot tree
cp -f pomera-dm250.dtb u-boot/dts/upstream/src/arm/rockchip/pomera-dm250.dtb

# 3. Patch defconfig for 100% Hands-Free Auto-Booting
echo ">> [3/5] Configuring U-Boot defconfig with automatic boot command..."
cd u-boot

python3 -c '
with open("configs/pomera-dm250_defconfig", "r") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    # Enable display output so user can see progress
    if any(k in line for k in ["CONFIG_SILENT_CONSOLE", "CONFIG_SILENT_U_BOOT_ONLY"]):
        continue
    if line.startswith("CONFIG_BOOTDELAY="):
        new_lines.append("CONFIG_BOOTDELAY=2\n")
    elif line.startswith("CONFIG_PREBOOT="):
        new_lines.append("CONFIG_PREBOOT=\"setenv stdin serial,tc3589x-keyb; setenv stdout serial,vidconsole; setenv stderr serial,vidconsole; fdt addr ${fdtcontroladdr}; fdt set /chosen stdout-path /framebuffer\"\n")
    elif line.startswith("CONFIG_BOOTCOMMAND="):
        # Dynamic storage-aware boot: Show distinct 1-line banners for SD Card Installer vs Internal Storage
        bootcmd = "if load mmc 1:1 0x62000000 efi/boot/bootarm.efi; then cls; echo; echo [Pomera DM250] Booting OpenBSD Installer (SD Card)...; echo; bootefi 0x62000000; elif load mmc 0:1 0x62000000 efi/boot/bootarm.efi; then cls; echo; echo [Pomera DM250] Starting OpenBSD from Internal Storage...; echo; bootefi 0x62000000; fi"
        new_lines.append(f"CONFIG_BOOTCOMMAND=\"{bootcmd}\"\n")
    else:
        new_lines.append(line)

new_lines.append("CONFIG_TOOLS_MKEFICAPSULE=n\n# CONFIG_TOOLS_MKEFICAPSULE is not set\n")

with open("configs/pomera-dm250_defconfig", "w") as f:
    f.writelines(new_lines)
'

# 4. Compile U-Boot
echo ">> [4/5] Building U-Boot (make pomera-dm250_defconfig && make -j${NPROC})..."
eval $MAKE_CMD ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" $HOST_EXTRA_FLAGS pomera-dm250_defconfig

# Ensure mkeficapsule remains disabled
python3 -c '
with open(".config", "r") as f:
    content = f.read().replace("CONFIG_TOOLS_MKEFICAPSULE=y", "# CONFIG_TOOLS_MKEFICAPSULE is not set")
with open(".config", "w") as f:
    f.write(content)
'

eval $MAKE_CMD ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" $HOST_EXTRA_FLAGS -j"$NPROC"

# 5. Package uboot.img using Rockchip loaderimage
echo ">> [5/5] Packaging Rockchip loader image (tools/loaderimage)..."
./tools/loaderimage --pack u-boot.bin "$OUTPUT_IMG"

# Pad to exact 512-byte sector multiples
size=$(wc -c < "$OUTPUT_IMG" | tr -d ' ')
rem=$(( size % 512 ))
if [ "$rem" -ne 0 ]; then
    pad=$(( 512 - rem ))
    dd if=/dev/zero bs=1 count="$pad" >> "$OUTPUT_IMG" 2>/dev/null
fi

img_size=$(ls -lh "$OUTPUT_IMG" | awk '{print $5}')
echo ""
echo "=========================================================="
echo "🎉 Successfully built auto-booting U-Boot!"
echo "   Output: ${OUTPUT_IMG} (${img_size})"
echo "   Auto-boot: load mmc 1:1 0x62000000 efi/boot/bootarm.efi || load mmc 0:1 0x62000000 efi/boot/bootarm.efi; bootefi 0x62000000"
echo "=========================================================="
