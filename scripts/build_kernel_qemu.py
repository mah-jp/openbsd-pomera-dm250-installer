#!/usr/bin/env python3
"""
build_kernel_qemu.py - Automated QEMU-based OpenBSD Kernel Builder for Pomera DM250.
Compiles a patched OpenBSD armv7 kernel (with DWC2 Split Transaction fix)
cleanly on macOS host using QEMU acceleration and authentic OpenBSD toolchains.

Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
SPDX-License-Identifier: MIT
"""

import os
import sys
import time
import socket
import shutil
import tarfile
import signal
import atexit
import threading
import subprocess
import functools
import http.server
import socketserver
import glob
import tempfile
import argparse
from typing import Optional, List

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
CACHE_DIR = os.path.join(REPO_ROOT, "_build_cache")
PATCH_FILE = os.path.join(SCRIPT_DIR, "patches", "dwc2_split_order_fix.patch")
OUTPUT_KERNEL = os.path.join(CACHE_DIR, "bsd.patched")

# Parse command-line arguments for work directory
parser = argparse.ArgumentParser(description="Build OpenBSD patched kernel via QEMU")
parser.add_argument("--work-dir", type=str, default=None, help="Working directory for disk images and temp files")
parser.add_argument("--no-clean", action="store_true", help="Keep build disk image and temp files after build")
parser.add_argument("--config", type=str, default="DM250", choices=["DM250", "GENERIC"],
                    help="Kernel configuration to build (default: DM250)")
parser.add_argument("--patch-usb", dest="patch_usb", action=argparse.BooleanOptionalAction, default=True,
                    help="Apply USB hub split transactions fix")
parser.add_argument("--patch-x11", dest="patch_x11", action=argparse.BooleanOptionalAction, default=True,
                    help="Apply X11 raw keys fix")
parser.add_argument("--patch-smode", dest="patch_smode", action=argparse.BooleanOptionalAction, default=True,
                    help="Apply rkdrm WSDISPLAYIO_SMODE fix for mlterm-fb framebuffer console")
parser.add_argument("--patch-bt", dest="patch_bt", action=argparse.BooleanOptionalAction, default=True,
                    help="Apply bcmbt 2s delay fix for Bluetooth UART attach")
args, _ = parser.parse_known_args()

if args.work_dir:
    WORK_DIR = os.path.abspath(args.work_dir)
    os.makedirs(WORK_DIR, exist_ok=True)
else:
    WORK_DIR = tempfile.mkdtemp(prefix="pomera_kbuild_")

print(f"==========================================================")
print(f">> Active working directory: {WORK_DIR}")
print(f"==========================================================")

EDK2_ARM64_PATHS = [
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/share/qemu/edk2-aarch64-code.fd",
    "/opt/homebrew/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd",
    "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
]

EDK2_ARM32_PATHS = [
    "/opt/homebrew/share/qemu/edk2-arm-code.fd",
    "/usr/local/share/qemu/edk2-arm-code.fd",
    "/opt/homebrew/Cellar/qemu/*/share/qemu/edk2-arm-code.fd",
    "/usr/local/Cellar/qemu/*/share/qemu/edk2-arm-code.fd",
    "/usr/share/AAVMF/AAVMF32_CODE.fd",
]


def find_firmware(paths: List[str]) -> str:
    for p in paths:
        matches = glob.glob(p)
        if matches:
            return sorted(matches)[-1]
    raise FileNotFoundError("EDK2 Firmware not found in standard paths.")


class DualDirectoryHandler(http.server.SimpleHTTPRequestHandler):
    """Serve files from WORK_DIR first, falling back to CACHE_DIR."""
    def __init__(self, *http_args, **http_kwargs):
        super().__init__(*http_args, directory=WORK_DIR, **http_kwargs)

    def translate_path(self, path):
        # First check WORK_DIR
        local_path = super().translate_path(path)
        if os.path.exists(local_path):
            return local_path
        # Fallback to CACHE_DIR
        rel_path = os.path.relpath(local_path, WORK_DIR)
        cache_path = os.path.join(CACHE_DIR, rel_path)
        if os.path.exists(cache_path):
            return cache_path
        return local_path

    def log_message(self, format, *log_args):
        pass


class BuildManager:
    def __init__(self):
        self.qemu_proc: Optional[subprocess.Popen] = None
        self.httpd: Optional[socketserver.TCPServer] = None
        self.serial_sock: Optional[str] = None
        self.temp_files: List[str] = []
        self._cleaned_up = False

        atexit.register(self.cleanup)
        signal.signal(signal.SIGINT, self._sig_handler)
        signal.signal(signal.SIGTERM, self._sig_handler)

    def _sig_handler(self, signum, frame):
        print("\n⚠️ Interrupted! Cleaning up...", file=sys.stderr)
        self.cleanup()
        sys.exit(1)

    def cleanup(self):
        if self._cleaned_up:
            return
        self._cleaned_up = True
        if self.qemu_proc and self.qemu_proc.poll() is None:
            try:
                self.qemu_proc.terminate()
                self.qemu_proc.wait(timeout=3)
            except Exception:
                try:
                    self.qemu_proc.kill()
                except Exception:
                    pass
        if self.httpd:
            try:
                self.httpd.shutdown()
                self.httpd.server_close()
            except Exception:
                pass
        if self.serial_sock and os.path.exists(self.serial_sock):
            try:
                os.remove(self.serial_sock)
            except Exception:
                pass
        if not args.no_clean:
            for tf in self.temp_files:
                if os.path.exists(tf):
                    try:
                        if os.path.isdir(tf):
                            shutil.rmtree(tf, ignore_errors=True)
                        else:
                            os.remove(tf)
                    except Exception:
                        pass


def prepare_patched_sys_archive(mgr: BuildManager) -> str:
    print(">> [1/4] Packaging patched OpenBSD kernel source tree...")
    archive_path = os.path.join(WORK_DIR, "sys_patched.tar.gz")
    mgr.temp_files.append(archive_path)

    # Locate base kernel source archive from cache or download automatically
    base_archive = None
    for candidate in [
        os.path.join(CACHE_DIR, "sys_rk3128.tar.gz"),
        os.path.join(WORK_DIR, "sys_rk3128.tar.gz"),
        os.path.join(CACHE_DIR, "sys.tar.gz"),
    ]:
        if os.path.exists(candidate) and os.path.getsize(candidate) > 1000000:
            base_archive = candidate
            break

    if not base_archive:
        print("   Kernel source cache not found. Fetching jcs/openbsd-src rk3128 branch (sys only)...")
        dest_archive = os.path.join(CACHE_DIR, "sys_rk3128.tar.gz")
        clone_tmp = tempfile.mkdtemp(prefix="pomera_src_")
        try:
            repo_dir = os.path.join(clone_tmp, "repo")
            subprocess.run(
                ["git", "clone", "--depth", "1", "--filter=blob:none", "--sparse",
                 "https://github.com/jcs/openbsd-src.git", "-b", "rk3128", repo_dir],
                check=True
            )
            subprocess.run(["git", "sparse-checkout", "set", "sys"], cwd=repo_dir, check=True)
            subprocess.run(["tar", "-czf", dest_archive, "-C", repo_dir, "sys"], check=True)
            base_archive = dest_archive
            print(f"   ✅ Successfully cached kernel sources to {dest_archive}")
        finally:
            shutil.rmtree(clone_tmp, ignore_errors=True)

    stage_dir = os.path.join(WORK_DIR, "sys_stage")
    if os.path.exists(stage_dir):
        shutil.rmtree(stage_dir)
    os.makedirs(stage_dir)

    print(f"   Extracting base source archive {base_archive} -> {stage_dir}...")
    subprocess.run(["tar", "-xzf", base_archive, "-C", stage_dir], check=True)

    target_dwc2 = os.path.join(stage_dir, "sys", "dev", "usb", "dwc2")

    # 1. Apply USB hub split transaction fix if enabled
    if args.patch_usb:
        dwc2_cache_dir = os.path.join(CACHE_DIR, "sys", "dev", "usb", "dwc2")
        if os.path.isdir(dwc2_cache_dir):
            print(f"   Injecting verified dwc2 driver fixes from {dwc2_cache_dir}...")
            for fname in os.listdir(dwc2_cache_dir):
                src_f = os.path.join(dwc2_cache_dir, fname)
                dst_f = os.path.join(target_dwc2, fname)
                if os.path.isfile(src_f):
                    shutil.copy2(src_f, dst_f)

        usb_patch = os.path.join(SCRIPT_DIR, "patches", "dwc2_split_order_fix.patch")
        if os.path.isfile(usb_patch):
            print("   Applying patch dwc2_split_order_fix.patch to staged tree...")
            subprocess.run(
                ["patch", "-p1", "--forward", "-r", "-"],
                input=open(usb_patch, "rb").read(),
                cwd=stage_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False
            )

        target_dwc2var = os.path.join(target_dwc2, "dwc2var.h")
        if os.path.isfile(target_dwc2var):
            with open(target_dwc2var, "r") as f:
                content = f.read()
                if "BITS_PER_LONG\t\t32" not in content and "BITS_PER_LONG 32" not in content:
                    raise RuntimeError("Verification failed: dwc2var.h does not contain BITS_PER_LONG 32 fix!")
            print("   ✅ Verified BITS_PER_LONG 32 in dwc2var.h")
    else:
        print("   ⏩ Skipping USB hub patch (disabled by user configuration)")

    # 2. Apply X11 raw keys fix if enabled
    if args.patch_x11:
        x11_patch = os.path.join(SCRIPT_DIR, "patches", "gpiokeys_rawkbd_fix.patch")
        if os.path.isfile(x11_patch):
            print("   Applying patch gpiokeys_rawkbd_fix.patch to staged tree...")
            subprocess.run(
                ["patch", "-p1", "--forward", "-r", "-"],
                input=open(x11_patch, "rb").read(),
                cwd=stage_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False
            )

        target_gpiokeys = os.path.join(stage_dir, "sys", "dev", "fdt", "gpiokeys.c")
        if os.path.isfile(target_gpiokeys):
            with open(target_gpiokeys, "r") as f:
                content = f.read()
                if "wskbd_is_raw(console_kbd)" not in content:
                    raise RuntimeError("Verification failed: gpiokeys.c does not contain wskbd_is_raw fix!")
            print("   ✅ Verified wskbd_is_raw in gpiokeys.c")

        target_wskbdvar = os.path.join(stage_dir, "sys", "dev", "wscons", "wskbdvar.h")
        if os.path.isfile(target_wskbdvar):
            with open(target_wskbdvar, "r") as f:
                content = f.read()
                if "wskbd_is_raw(struct device *)" not in content:
                    raise RuntimeError("Verification failed: wskbdvar.h does not contain wskbd_is_raw declaration!")
            print("   ✅ Verified wskbd_is_raw declaration in wskbdvar.h")
    else:
        print("   ⏩ Skipping X11 keys patch (disabled by user configuration)")

    # 3. Apply rkdrm WSDISPLAYIO_SMODE fix for mlterm-fb framebuffer console
    if args.patch_smode:
        smode_patch = os.path.join(SCRIPT_DIR, "patches", "rkdrm_wsdisplay_smode.patch")
        if os.path.isfile(smode_patch):
            print("   Applying patch rkdrm_wsdisplay_smode.patch to staged tree...")
            subprocess.run(
                ["patch", "-p1", "--forward", "-r", "-"],
                input=open(smode_patch, "rb").read(),
                cwd=stage_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False
            )

        target_rkdrm = os.path.join(stage_dir, "sys", "dev", "fdt", "rkdrm.c")
        if os.path.isfile(target_rkdrm):
            with open(target_rkdrm, "r") as f:
                content = f.read()
                if "WSDISPLAYIO_SMODE:" not in content:
                    raise RuntimeError("Verification failed: rkdrm.c does not contain WSDISPLAYIO_SMODE fix!")
            print("   ✅ Verified WSDISPLAYIO_SMODE in rkdrm.c")
    else:
        print("   ⏩ Skipping rkdrm SMODE patch (disabled by user configuration)")

    # 4. Apply bcmbt 2s delay fix for Bluetooth UART attach
    if args.patch_bt:
        bt_patch = os.path.join(SCRIPT_DIR, "patches", "bcmbt_delay_2s.patch")
        if os.path.isfile(bt_patch):
            print("   Applying patch bcmbt_delay_2s.patch to staged tree...")
            subprocess.run(
                ["patch", "-p1", "--forward", "-r", "-"],
                input=open(bt_patch, "rb").read(),
                cwd=stage_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False
            )

        target_bcmbt = os.path.join(stage_dir, "sys", "dev", "fdt", "bcmbt_fdt.c")
        if os.path.isfile(target_bcmbt):
            with open(target_bcmbt, "r") as f:
                content = f.read()
                if "delay(2000000)" not in content:
                    raise RuntimeError("Verification failed: bcmbt_fdt.c does not contain delay(2000000) fix!")
            print("   ✅ Verified delay(2000000) in bcmbt_fdt.c")
    else:
        print("   ⏩ Skipping Bluetooth patch (disabled by user configuration)")

    # Inject DM250 optimized kernel configuration if available
    conf_dm250 = os.path.join(SCRIPT_DIR, "conf", "DM250")
    if os.path.isfile(conf_dm250):
        target_conf_dir = os.path.join(stage_dir, "sys", "arch", "armv7", "conf")
        os.makedirs(target_conf_dir, exist_ok=True)
        shutil.copy2(conf_dm250, os.path.join(target_conf_dir, "DM250"))
        print(f"   ✅ Injected DM250 optimized kernel configuration -> {os.path.join(target_conf_dir, 'DM250')}")

    print(f"   Creating final patched archive {archive_path}...")
    subprocess.run(
        ["tar", "-czf", archive_path, "-C", stage_dir, "sys"],
        check=True
    )
    shutil.rmtree(stage_dir)
    print("   ✅ Kernel source archive ready.")
    return archive_path


def main():
    target_config = args.config
    print("=================================================================")
    print(f"🛠️  OpenBSD Pomera DM250 Patched Kernel Builder (Config: {target_config})")
    print("=================================================================")

    mgr = BuildManager()

    sys_archive = prepare_patched_sys_archive(mgr)

    # Start ephemeral HTTP server to serve sys_patched.tar.gz, base79.tgz, comp79.tgz
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(("127.0.0.1", 0), DualDirectoryHandler)
    http_port = httpd.server_address[1]
    mgr.httpd = httpd

    http_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    http_thread.start()
    print(f">> Local HTTP server running on port {http_port}")

    # Build disk image (4GB)
    disk_img = os.path.join(WORK_DIR, "kernel_build_disk.img")
    mgr.temp_files.append(disk_img)
    if os.path.exists(disk_img):
        os.remove(disk_img)

    print(f">> [2/4] Initializing build disk image ({disk_img}, 4GB)...")
    with open(disk_img, "wb") as f:
        f.truncate(4 * 1024 * 1024 * 1024)

    # Ensure all required assets exist in CACHE_DIR or WORK_DIR
    def ensure_asset(filename: str, url: str):
        if os.path.exists(os.path.join(WORK_DIR, filename)) or os.path.exists(os.path.join(CACHE_DIR, filename)):
            return
        dest = os.path.join(CACHE_DIR, filename)
        print(f"   Downloading required asset {filename} from {url}...")
        subprocess.run(["curl", "-sSL", "-f", "--retry", "5", "--retry-delay", "3", url, "-o", dest], check=True)

    ensure_asset("miniroot79.img", "https://cdn.openbsd.org/pub/OpenBSD/7.9/arm64/miniroot79.img")
    ensure_asset("base79.tgz", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/base79.tgz")
    ensure_asset("comp79.tgz", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/comp79.tgz")
    ensure_asset("BOOTARM.EFI", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/BOOTARM.EFI")
    ensure_asset("bsd_generic", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/bsd")

    # Phase 1: Use QEMU aarch64 (HVF native speed) to format FFS and extract sets + source
    edk2_arm64 = find_firmware(EDK2_ARM64_PATHS)
    miniroot_img = os.path.join(WORK_DIR, "miniroot79.img")
    if not os.path.exists(miniroot_img):
        miniroot_img = os.path.join(CACHE_DIR, "miniroot79.img")

    print(">> Provisioning build disk via high-speed QEMU arm64 (HVF)...")
    serial_sock = f"/tmp/pomera-kbuild-serial-{os.getpid()}.sock"
    mgr.serial_sock = serial_sock

    prep_script_content = f"""#!/bin/sh
set -e
echo "=== STAGE 1: FORMATTING BUILD DISK ==="
cd /dev && sh MAKEDEV sd1
fdisk -iy -b "204800@32768:C" sd1
disklabel -E sd1 << 'EOF_LABEL'
a




w
q
EOF_LABEL
newfs -b 16384 -f 2048 -i 16384 /dev/rsd1a
newfs_msdos /dev/rsd1i
mount /dev/sd1a /mnt
mkdir -p /mnt/mnt_fat
mount /dev/sd1i /mnt/mnt_fat
mkdir -p /mnt/mnt_fat/efi/boot

echo "=== STAGE 2: EXTRACTING TOOLCHAIN & KERNEL SOURCE ==="
ftp -o /mnt/base79.tgz http://10.0.2.2:{http_port}/base79.tgz
ftp -o /mnt/comp79.tgz http://10.0.2.2:{http_port}/comp79.tgz
ftp -o /mnt/sys_patched.tar.gz http://10.0.2.2:{http_port}/sys_patched.tar.gz
ftp -o /mnt/bsd http://10.0.2.2:{http_port}/bsd_generic
ftp -o /mnt/mnt_fat/efi/boot/BOOTARM.EFI http://10.0.2.2:{http_port}/BOOTARM.EFI

tar -xzphf /mnt/base79.tgz -C /mnt
tar -xzphf /mnt/comp79.tgz -C /mnt
if [ -f /mnt/var/sysmerge/etc.tgz ]; then
    tar -xzphf /mnt/var/sysmerge/etc.tgz -C /mnt
fi
mkdir -p /mnt/usr/src
tar -xzf /mnt/sys_patched.tar.gz -C /mnt/usr/src
rm -f /mnt/base79.tgz /mnt/comp79.tgz /mnt/sys_patched.tar.gz

pwd_mkdb -p -d /mnt/etc /mnt/etc/master.passwd
mkdir -p /mnt/usr/obj
chown root:wobj /mnt/usr/obj 2>/dev/null || true
chmod 775 /mnt/usr/obj || true

cd /mnt/dev && ./MAKEDEV all

# Configure fstab
cat << 'EOF_FSTAB' > /mnt/etc/fstab
/dev/sd0a / ffs rw 1 1
/dev/sd0i /mnt_fat msdos rw 1 2
EOF_FSTAB

# Configure network for virtio-net
echo "kbuilder.localdomain" > /mnt/etc/myname
echo "inet autoconf" > /mnt/etc/hostname.vio0

# Optimize boot & compilation speed
cat << 'EOF_BOOT' > /mnt/etc/boot.conf
set timeout 1
EOF_BOOT

cat << 'EOF_RCCONF' > /mnt/etc/rc.conf.local
library_aslr=NO
check_quotas=NO
pf=NO
multicast=NO
apmd_flags=NO
sndiod_flags=NO
sshd_flags=NO
smtpd_flags=NO
syslogd_flags=NO
ntpd_flags=NO
EOF_RCCONF

# Configure automatic build script in rc.local
cat << 'EOF_RC' > /mnt/etc/rc.local
echo "=========================================================="
echo ">> [QEMU-ARMV7] Starting Patched Kernel Compilation ({target_config})..."
echo "=========================================================="
cd /usr/src/sys/arch/armv7/conf
/usr/sbin/config {target_config}
cd /usr/src/sys/arch/armv7/compile/{target_config}
make clean || true
make -j4
if [ -f bsd ]; then
    K=bsd
elif [ -f /usr/obj/sys/arch/armv7/compile/{target_config}/bsd ]; then
    K=/usr/obj/sys/arch/armv7/compile/{target_config}/bsd
else
    echo "❌ Kernel build failed!"
    sync
    sleep 2
    halt -p
fi

echo ">> Kernel build successful! Target: $K"
ls -lh $K
file $K
sha256 $K

echo ">> Copying kernel directly to FAT partition (/mnt_fat/bsd.patched)..."
cp $K /mnt_fat/bsd.patched
sync
sync
echo ">> Verifying copy on FAT partition:"
ls -lh /mnt_fat/bsd.patched
sha256 /mnt_fat/bsd.patched
echo ">> Export complete. Halting VM cleanly..."
sleep 2
halt -p
EOF_RC
chmod +x /mnt/etc/rc.local

echo "=== STAGE 1 COMPLETE! HALTING VM ==="
cd /
umount /mnt/mnt_fat || true
umount /mnt || true
sync
sleep 1
halt -p
"""

    prep_script_path = os.path.join(WORK_DIR, "prep_kbuild.sh")
    mgr.temp_files.append(prep_script_path)
    with open(prep_script_path, "w") as f:
        f.write(prep_script_content)

    qemu_cmd = [
        "qemu-system-aarch64",
        "-M", "virt,accel=hvf:tcg",
        "-cpu", "host" if sys.platform == "darwin" else "cortex-a57",
        "-m", "1024M",
        "-smp", "4",
        "-bios", edk2_arm64,
        "-drive", f"file={miniroot_img},format=raw,if=virtio,readonly=on",
        "-drive", f"file={disk_img},format=raw,if=virtio",
        "-netdev", "user,id=net0",
        "-device", "virtio-net,netdev=net0",
        "-display", "none",
        "-serial", f"unix:{serial_sock},server,nowait",
        "-no-reboot",
    ]

    p = subprocess.Popen(qemu_cmd)
    mgr.qemu_proc = p

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connected = False
    for _ in range(30):
        if os.path.exists(serial_sock):
            try:
                s.connect(serial_sock)
                connected = True
                break
            except Exception:
                pass
        time.sleep(0.5)

    if not connected:
        raise TimeoutError("Failed to connect to QEMU serial socket.")

    s.settimeout(1.0)
    buf = b""
    stage1_done = False
    while True:
        if p.poll() is not None:
            break
        try:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()

            if b"erase ^?, werase ^W, kill ^U, intr ^C, status ^T" in buf:
                buf = b""
                time.sleep(1)
                s.sendall(b"s\n")
            elif b"# " in buf and not stage1_done:
                buf = b""
                print("\n>> [host] Configuring network via DHCP and launching prep script...")
                cmd = f"ifconfig vio0 inet autoconf; sleep 2; ftp -V -o /tmp/prep.sh http://10.0.2.2:{http_port}/prep_kbuild.sh && sh /tmp/prep.sh\n"
                s.sendall(cmd.encode("ascii"))
                stage1_done = True
        except socket.timeout:
            continue

    p.wait()
    print(">> Stage 1 provisioning complete.")

    # Phase 2: Boot disk in QEMU armv7 (32-bit ARM) to compile kernel natively!
    print(">> [3/4] Booting QEMU ARMv7 VM for native kernel compilation...")
    edk2_arm32 = find_firmware(EDK2_ARM32_PATHS)
    print(f"   Using EDK2 ARM32: {edk2_arm32}")

    if os.path.exists(serial_sock):
        os.remove(serial_sock)

    qemu_arm32_cmd = [
        "qemu-system-arm",
        "-M", "virt",
        "-cpu", "cortex-a15",
        "-m", "2048M",
        "-smp", "4",
        "-bios", edk2_arm32,
        "-drive", f"file={disk_img},format=raw,if=virtio",
        "-netdev", "user,id=net0",
        "-device", "virtio-net,netdev=net0",
        "-display", "none",
        "-serial", f"unix:{serial_sock},server,nowait",
        "-no-reboot",
    ]

    p32 = subprocess.Popen(qemu_arm32_cmd)
    mgr.qemu_proc = p32

    s32 = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(30):
        if os.path.exists(serial_sock):
            try:
                s32.connect(serial_sock)
                break
            except Exception:
                pass
        time.sleep(0.5)

    s32.settimeout(1.0)
    buf32 = b""
    while True:
        if p32.poll() is not None:
            break
        try:
            chunk = s32.recv(4096)
            if not chunk:
                break
            buf32 += chunk
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()

            if b"boot>" in buf32:
                buf32 = b""
                s32.sendall(b"boot\n")
        except socket.timeout:
            continue

    p32.wait()
    print("\n>> Stage 2 kernel compilation VM finished.")

    # Phase 3: Extract bsd.patched from FAT partition
    print(">> [4/4] Extracting bsd.patched from FAT partition...")
    extract_from_fat(disk_img, OUTPUT_KERNEL)

    if os.path.exists(OUTPUT_KERNEL) and os.path.getsize(OUTPUT_KERNEL) > 1000000:
        print("=================================================================")
        print(f"🎉 SUCCESS! Patched kernel built and exported to:")
        print(f"   {OUTPUT_KERNEL}")
        print(f"   Size: {os.path.getsize(OUTPUT_KERNEL)} bytes")
        print("=================================================================")
        subprocess.run(["file", OUTPUT_KERNEL])
    else:
        print("❌ Error: Patched kernel was not successfully extracted.")
        sys.exit(1)


def extract_from_fat(disk_img: str, output_path: str):
    """Extract bsd.patched from FAT partition using macOS hdiutil."""
    print(">> Attaching disk image to mount FAT partition...")
    try:
        out = subprocess.check_output([
            "hdiutil", "attach",
            "-imagekey", "diskimage-class=CRawDiskImage",
            disk_img
        ]).decode("utf-8")
        disk_id = None
        mount_point = None
        for line in out.strip().split("\n"):
            if "Windows_FAT_32" in line or "DOS_FAT_16" in line:
                if "/Volumes/" in line:
                    mount_point = line[line.index("/Volumes/"):]
            if line.startswith("/dev/disk"):
                disk_id = line.split()[0]
        if mount_point:
            fat_bsd = os.path.join(mount_point, "bsd.patched")
            if os.path.exists(fat_bsd):
                print(f"   Copying {fat_bsd} -> {output_path}...")
                shutil.copy2(fat_bsd, output_path)
                print(f"   ✅ Successfully extracted {output_path} ({os.path.getsize(output_path)} bytes)")
            else:
                print(f"⚠️ {fat_bsd} not found on mounted FAT partition!")
        if disk_id:
            subprocess.run(["hdiutil", "detach", disk_id], check=False)
    except Exception as e:
        print(f"⚠️ hdiutil error: {e}")


if __name__ == "__main__":
    main()
