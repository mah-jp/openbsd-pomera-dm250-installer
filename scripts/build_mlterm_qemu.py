#!/usr/bin/env python3
"""
build_mlterm_qemu.py - Automated QEMU-based mlterm-fb Builder for Pomera DM250.
Compiles a patched OpenBSD armv7 mlterm-fb (with shadowfb and Japanese fonts engine)
cleanly on macOS / Linux host using QEMU acceleration and authentic OpenBSD toolchains.

Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
SPDX-License-Identifier: MIT
"""

import os
import sys
import time
import socket
import shutil
import signal
import atexit
import threading
import subprocess
import http.server
import socketserver
import glob
import tempfile
import argparse
import urllib.request
from typing import Optional, List

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
CACHE_DIR = os.path.join(REPO_ROOT, "_build_cache")
PATCH_FILE = os.path.join(SCRIPT_DIR, "patches", "mlterm-fb-dm250-shadowfb.patch")
DEFAULT_OUTPUT = os.path.join(CACHE_DIR, "mlterm-fb-dm250.tar.gz")

parser = argparse.ArgumentParser(description="Build OpenBSD patched mlterm-fb via QEMU")
parser.add_argument("--work-dir", type=str, default=None, help="Working directory for disk images and temp files")
parser.add_argument("--output", type=str, default=DEFAULT_OUTPUT, help="Destination path for mlterm-fb archive")
parser.add_argument("--no-clean", action="store_true", help="Keep build disk image and temp files after build")
parser.add_argument("--force", action="store_true", help="Force rebuild even if output already exists")
args, _ = parser.parse_known_args()

if args.work_dir:
    WORK_DIR = os.path.abspath(args.work_dir)
    os.makedirs(WORK_DIR, exist_ok=True)
else:
    WORK_DIR = tempfile.mkdtemp(prefix="pomera_mlterm_build_")

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
    """Serve files from WORK_DIR first, falling back to CACHE_DIR and SCRIPT_DIR."""
    def __init__(self, *http_args, **http_kwargs):
        super().__init__(*http_args, directory=WORK_DIR, **http_kwargs)

    def translate_path(self, path):
        local_path = super().translate_path(path)
        if os.path.exists(local_path):
            return local_path
        rel_path = os.path.relpath(local_path, WORK_DIR)
        cache_path = os.path.join(CACHE_DIR, rel_path)
        if os.path.exists(cache_path):
            return cache_path
        patch_path = os.path.join(SCRIPT_DIR, "patches", rel_path)
        if os.path.exists(patch_path):
            return patch_path
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


def ensure_asset(filename: str, url: str) -> str:
    path = os.path.join(CACHE_DIR, filename)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        print(f">> Fetching {filename} from {url}...")
        req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88.1"})
        with urllib.request.urlopen(req) as resp, open(path, "wb") as f:
            shutil.copyfileobj(resp, f)
        print(f"   ✅ Saved {filename} ({os.path.getsize(path)} bytes)")
    return path


def extract_from_fat(disk_img: str, output_path: str):
    """Extract mlterm-fb-dm250.tar.gz from FAT partition."""
    print(">> Attaching disk image to mount FAT partition...")
    if sys.platform == "darwin":
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
                fat_archive = os.path.join(mount_point, "mlterm-fb-dm250.tar.gz")
                if os.path.exists(fat_archive):
                    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
                    shutil.copy2(fat_archive, output_path)
                    print(f"   ✅ Successfully extracted {output_path} ({os.path.getsize(output_path)} bytes)")
                else:
                    print(f"⚠️ {fat_archive} not found on mounted FAT partition!")
            if disk_id:
                subprocess.run(["hdiutil", "detach", disk_id], check=False)
        except Exception as e:
            print(f"⚠️ hdiutil error: {e}")
    else:
        # Linux fallback using mcopy or loop mount
        try:
            # FAT partition offset is 32768 sectors * 512 = 16777216 bytes
            offset = 32768 * 512
            if os.path.exists(output_path):
                os.remove(output_path)
            if shutil.which('mcopy'):
                subprocess.run(['mcopy', '-o', '-i', f'{disk_img}@@{offset}', '::mlterm-fb-dm250.tar.gz', output_path], check=True)
                print(f'   ✅ Extracted with mcopy: {output_path}')
            else:
                mnt_tmp = tempfile.mkdtemp(prefix="fat_mnt_")
                subprocess.run(["mount", "-o", f"loop,offset={offset}", disk_img, mnt_tmp], check=True)
                shutil.copy2(os.path.join(mnt_tmp, "mlterm-fb-dm250.tar.gz"), output_path)
                subprocess.run(["umount", mnt_tmp], check=False)
                os.rmdir(mnt_tmp)
                print(f"   ✅ Extracted with loop mount: {output_path}")
        except Exception as e:
            print(f"⚠️ Linux extract error: {e}")


def main():
    if os.path.exists(args.output) and not args.force and os.path.getsize(args.output) > 50000:
        print(f">> Existing mlterm-fb archive found at {args.output} ({os.path.getsize(args.output)} bytes).")
        print("   Use --force to rebuild via QEMU.")
        return 0

    print("==========================================================")
    print("  Pomera DM250 mlterm-fb Automated QEMU Builder")
    print("==========================================================")
    print(f">> Active working directory: {WORK_DIR}")

    mgr = BuildManager()
    if not args.work_dir:
        mgr.temp_files.append(WORK_DIR)

    # 1. Start ephemeral HTTP server
    handler = DualDirectoryHandler
    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    http_port = httpd.server_address[1]
    mgr.httpd = httpd

    http_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    http_thread.start()
    print(f">> Local caching HTTP server active on port {http_port}")

    # 2. Ensure required assets
    print(">> [1/4] Ensuring build assets and OpenBSD 7.9 sets...")
    ensure_asset("base79.tgz", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/base79.tgz")
    ensure_asset("comp79.tgz", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/comp79.tgz")
    ensure_asset("xbase79.tgz", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/xbase79.tgz")
    ensure_asset("xshare79.tgz", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/xshare79.tgz")
    ensure_asset("BOOTARM.EFI", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/BOOTARM.EFI")
    ensure_asset("bsd_generic", "https://cdn.openbsd.org/pub/OpenBSD/7.9/armv7/bsd")
    ensure_asset("miniroot79.img", "https://cdn.openbsd.org/pub/OpenBSD/7.9/arm64/miniroot79.img")
    ensure_asset("mlterm-3.9.5.tar.gz", "https://github.com/arakiken/mlterm/archive/refs/tags/3.9.5.tar.gz")

    # 3. Create build disk image
    disk_img = os.path.join(WORK_DIR, "mlterm_build_disk.img")
    mgr.temp_files.append(disk_img)
    print(">> Allocating 4GB sparse disk image for build VM...")
    with open(disk_img, "wb") as f:
        f.truncate(4096 * 1024 * 1024)

    # 4. Phase 1: High-Speed Provisioning via QEMU ARM64 (HVF)
    print(">> [2/4] Provisioning build disk via high-speed QEMU arm64 (HVF)...")
    edk2_arm64 = find_firmware(EDK2_ARM64_PATHS)
    miniroot_img = os.path.join(CACHE_DIR, "miniroot79.img")

    serial_sock = f"/tmp/pomera-mlterm-serial-{os.getpid()}.sock"
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

echo "=== STAGE 2: EXTRACTING TOOLCHAIN & SETS ==="
ftp -o /mnt/base79.tgz http://10.0.2.2:{http_port}/base79.tgz
ftp -o /mnt/comp79.tgz http://10.0.2.2:{http_port}/comp79.tgz
ftp -o /mnt/xbase79.tgz http://10.0.2.2:{http_port}/xbase79.tgz
ftp -o /mnt/xshare79.tgz http://10.0.2.2:{http_port}/xshare79.tgz
ftp -o /mnt/bsd http://10.0.2.2:{http_port}/bsd_generic
ftp -o /mnt/mnt_fat/efi/boot/BOOTARM.EFI http://10.0.2.2:{http_port}/BOOTARM.EFI
ftp -o /mnt/mlterm-3.9.5.tar.gz http://10.0.2.2:{http_port}/mlterm-3.9.5.tar.gz
ftp -o /mnt/mlterm-fb-dm250-shadowfb.patch http://10.0.2.2:{http_port}/mlterm-fb-dm250-shadowfb.patch
ftp -o /mnt/mlterm-fb-dm250-optimized.patch http://10.0.2.2:{http_port}/mlterm-fb-dm250-optimized.patch

tar -xzphf /mnt/base79.tgz -C /mnt
tar -xzphf /mnt/comp79.tgz -C /mnt
tar -xzphf /mnt/xbase79.tgz -C /mnt
tar -xzphf /mnt/xshare79.tgz -C /mnt
if [ -f /mnt/var/sysmerge/etc.tgz ]; then
    tar -xzphf /mnt/var/sysmerge/etc.tgz -C /mnt
fi
rm -f /mnt/base79.tgz /mnt/comp79.tgz /mnt/xbase79.tgz /mnt/xshare79.tgz

pwd_mkdb -p -d /mnt/etc /mnt/etc/master.passwd
cd /mnt/dev && ./MAKEDEV all

cat << 'EOF_FSTAB' > /mnt/etc/fstab
/dev/sd0a / ffs rw 1 1
/dev/sd0i /mnt_fat msdos rw 1 2
EOF_FSTAB

echo "mlbuilder.localdomain" > /mnt/etc/myname
echo "inet autoconf" > /mnt/etc/hostname.vio0

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

cat << 'EOF_RC' > /mnt/etc/rc.local
echo "=========================================================="
echo ">> [QEMU-ARMV7] Building [1/2] Baseline mlterm-fb (3.9.5)..."
echo "=========================================================="
cd /usr/src
tar -xzf /mlterm-3.9.5.tar.gz
cd mlterm-3.9.5
echo ">> Applying Pomera baseline shadowfb patch..."
patch -p1 < /mlterm-fb-dm250-shadowfb.patch
./configure --prefix=/usr/local --sysconfdir=/etc --with-gui=fb --with-type-engines=xcore --enable-shared --disable-static --disable-nls --enable-skk
make -j4
make install
cp -f /usr/local/bin/mlterm-fb /usr/local/bin/mlterm-fb.orig
strip /usr/local/bin/mlterm-fb

echo "=========================================================="
echo ">> [QEMU-ARMV7] Building [2/2] Optimized mlterm-fb-pomera (3.9.5)..."
echo "=========================================================="
cd /usr/src
rm -rf mlterm-3.9.5
tar -xzf /mlterm-3.9.5.tar.gz
cd mlterm-3.9.5
echo ">> Applying Pomera turbocharged optimization patch..."
patch -p1 < /mlterm-fb-dm250-optimized.patch
export CFLAGS="-O2 -pipe -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=softfp"
./configure --prefix=/usr/local --sysconfdir=/etc --with-gui=fb --with-type-engines=xcore --enable-shared --disable-static --disable-nls --enable-skk
make -j4
make install
cp -f /usr/local/bin/mlterm-fb /usr/local/bin/mlterm-fb-pomera
cp -f /usr/local/bin/mlterm-fb.orig /usr/local/bin/mlterm-fb
strip /usr/local/bin/mlterm-fb-pomera

echo ">> Creating convenient command symlinks:"
ln -sf mlterm-fb /usr/local/bin/mlterm-base
ln -sf mlterm-fb-pomera /usr/local/bin/mlterm-opt

echo ">> Verifying binaries:"
ls -lh /usr/local/bin/mlterm-fb /usr/local/bin/mlterm-fb-pomera /usr/local/bin/mlterm-base /usr/local/bin/mlterm-opt

echo ">> Packaging both binaries, runtime shared libraries, and input plugins..."
cd /
files_to_pack="usr/local/bin/mlterm-fb usr/local/bin/mlterm-fb-pomera usr/local/bin/mlterm-base usr/local/bin/mlterm-opt"
for item in usr/local/lib/libmef.so.* usr/local/lib/libpobl.so.* usr/local/lib/libmlterm* usr/local/lib/mlterm usr/local/lib/mef; do
    if [ -e "/$item" ]; then
        files_to_pack="$files_to_pack $item"
    fi
done
tar -czf /mnt_fat/mlterm-fb-dm250.tar.gz $files_to_pack

echo ">> Exported to FAT partition:"
ls -lh /mnt_fat/mlterm-fb-dm250.tar.gz
sync
sync
echo ">> Compilation complete! Halting VM..."
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
    prep_script_path = os.path.join(WORK_DIR, "prep_mlterm.sh")
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
                cmd = f"ifconfig vio0 inet autoconf; sleep 2; ftp -V -o /tmp/prep.sh http://10.0.2.2:{http_port}/prep_mlterm.sh && sh /tmp/prep.sh\n"
                s.sendall(cmd.encode("ascii"))
                stage1_done = True
        except socket.timeout:
            continue

    p.wait()
    print(">> Stage 1 provisioning complete.")

    # 5. Phase 2: Native compilation via QEMU ARMv7
    print(">> [3/4] Booting QEMU ARMv7 VM for native compilation...")
    edk2_arm32 = find_firmware(EDK2_ARM32_PATHS)

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
    print("\n>> Stage 2 native compilation VM finished.")

    # 6. Phase 3: Extract mlterm-fb-dm250.tar.gz from FAT partition
    print(">> [4/4] Extracting mlterm-fb-dm250.tar.gz from FAT partition...")
    extract_from_fat(disk_img, args.output)

    if os.path.exists(args.output) and os.path.getsize(args.output) > 50000:
        print("=================================================================")
        print(f"🎉 SUCCESS! mlterm-fb built and exported to:")
        print(f"   {args.output}")
        print(f"   Size: {os.path.getsize(args.output)} bytes")
        print("=================================================================")
        subprocess.run(["tar", "-tzvf", args.output])
        return 0
    else:
        print("❌ Error: mlterm-fb archive was not successfully extracted.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
