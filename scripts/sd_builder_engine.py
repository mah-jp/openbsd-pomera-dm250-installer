#!/usr/bin/env python3
"""
sd_builder_engine.py - Unified Core Engine for OpenBSD DM250 SD / Golden Image Generation.
Provides robust resource management, bulletproof SIGINT/Ctrl+C process termination,
ephemeral HTTP port allocation, atomic file generation, and QEMU automation.

Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
SPDX-License-Identifier: MIT
"""

import os
import sys
import io
import time
import socket
import shutil
import tarfile
import signal
import atexit
import threading
import subprocess
import http.server
import socketserver
import glob
import platform
import re
import functools
from typing import Optional, List, Tuple

# Attempt top-level import of create_idbloader conforming to PEP 8
try:
    from make_idbloader import create_idbloader
except ImportError:
    try:
        from scripts.make_idbloader import create_idbloader
    except ImportError:
        create_idbloader = None


def fix_file_ownership(target_path: str) -> None:
    """
    Restore file/directory ownership to SUDO_USER when run via sudo.
    Adopts the proven pomera-dm250-backup-restore-tool convention.
    """
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user and sudo_user != "root" and os.geteuid() == 0 and os.path.exists(target_path):
        try:
            subprocess.run(["chown", "-R", sudo_user, target_path], stderr=subprocess.DEVNULL, check=False)
        except Exception:
            pass


# Supported EDK2 UEFI firmware search paths across Linux & macOS (Apple Silicon & Intel)
EDK2_PATHS = [
    "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
    "/usr/share/AAVMF/AAVMF_CODE.fd",
    "/usr/share/edk2/aarch64/QEMU_EFI.fd",
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/share/qemu/edk2-aarch64-code.fd",
    "/opt/homebrew/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd",
]


class SilentHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP request handler that suppresses access logging."""
    def log_message(self, format, *args):
        pass


class ResourceManager:
    """
    Centralized resource manager to ensure 100% clean shutdown on normal exit,
    unexpected exceptions, or termination signals (SIGINT/Ctrl+C, SIGTERM).
    """
    def __init__(self, work_dir: str, configs_dir: str):
        self.work_dir = work_dir
        self.configs_dir = configs_dir
        self.qemu_proc: Optional[subprocess.Popen] = None
        self.httpd: Optional[socketserver.TCPServer] = None
        self.serial_sock: Optional[str] = None
        self.temp_dirs: List[str] = []
        self.temp_files: List[str] = []
        self.done_event = threading.Event()
        self._cleaned_up = False
        self._lock = threading.Lock()

        # Register standard exit and signal handlers
        atexit.register(self.cleanup)
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

    def _signal_handler(self, signum, frame):
        sig_name = "SIGINT (Ctrl+C)" if signum == signal.SIGINT else f"Signal {signum}"
        print(f"\n⚠️  Interrupted by {sig_name}! Performing emergency cleanup...", file=sys.stderr)
        self.cleanup()
        sys.exit(128 + signum)

    def register_temp_dir(self, dir_path: str):
        with self._lock:
            if dir_path not in self.temp_dirs:
                self.temp_dirs.append(dir_path)

    def unregister_temp_dir(self, dir_path: str):
        with self._lock:
            if dir_path in self.temp_dirs:
                self.temp_dirs.remove(dir_path)

    def register_temp_file(self, file_path: str):
        with self._lock:
            if file_path not in self.temp_files:
                self.temp_files.append(file_path)

    def unregister_temp_file(self, file_path: str):
        with self._lock:
            if file_path in self.temp_files:
                self.temp_files.remove(file_path)

    def cleanup(self):
        with self._lock:
            if self._cleaned_up:
                return
            self._cleaned_up = True

        self.done_event.set()

        # 1. Terminate QEMU child process immediately to prevent device locks
        if self.qemu_proc:
            try:
                if self.qemu_proc.poll() is None:
                    print(">> [cleanup] Terminating QEMU process...", file=sys.stderr)
                    try:
                        os.killpg(os.getpgid(self.qemu_proc.pid), signal.SIGTERM)
                    except Exception:
                        self.qemu_proc.terminate()

                    try:
                        self.qemu_proc.wait(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        print(">> [cleanup] Forcefully killing QEMU process...", file=sys.stderr)
                        try:
                            os.killpg(os.getpgid(self.qemu_proc.pid), signal.SIGKILL)
                        except Exception:
                            self.qemu_proc.kill()
                        self.qemu_proc.wait(timeout=1.0)
            except Exception as e:
                print(f"⚠️  [cleanup] Error stopping QEMU: {e}", file=sys.stderr)
            finally:
                self.qemu_proc = None

        # 2. Shutdown and close local HTTP distribution server
        if self.httpd:
            try:
                self.httpd.shutdown()
                self.httpd.server_close()
            except Exception as e:
                print(f"⚠️  [cleanup] Error shutting down HTTP server: {e}", file=sys.stderr)
            finally:
                self.httpd = None

        # 3. Remove serial UNIX socket
        if self.serial_sock and os.path.exists(self.serial_sock):
            try:
                os.remove(self.serial_sock)
            except Exception:
                pass
            self.serial_sock = None

        # 4. Remove registered temporary files
        for tfile in self.temp_files:
            if os.path.exists(tfile):
                try:
                    os.remove(tfile)
                except Exception:
                    pass
        self.temp_files.clear()

        # 5. Remove registered temporary directories
        for tdir in self.temp_dirs:
            if os.path.exists(tdir):
                try:
                    shutil.rmtree(tdir, ignore_errors=True)
                except Exception:
                    pass
        self.temp_dirs.clear()

        # 6. Restore file/dir ownership if run via sudo (pomera-dm250-backup-restore-tool convention)
        fix_file_ownership(self.configs_dir)
        if os.path.exists(self.work_dir):
            for fname in os.listdir(self.work_dir):
                fpath = os.path.join(self.work_dir, fname)
                if os.path.isfile(fpath):
                    try:
                        if os.stat(fpath).st_uid == 0:
                            fix_file_ownership(fpath)
                    except Exception:
                        pass


def find_free_port() -> int:
    """Find and return an available ephemeral TCP port on localhost."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        return s.getsockname()[1]


def find_edk2_firmware() -> str:
    """Locate valid EDK2 aarch64 UEFI firmware."""
    for p in EDK2_PATHS:
        matched = glob.glob(p)
        if matched and os.path.exists(matched[0]):
            return matched[0]
    raise FileNotFoundError("EDK2 aarch64 firmware not found in known system locations.")


def get_qemu_accelerator() -> List[str]:
    """Determine host architecture and appropriate QEMU acceleration flag."""
    uname_s = subprocess.check_output(["uname", "-s"]).decode().strip()
    uname_m = subprocess.check_output(["uname", "-m"]).decode().strip()

    if uname_s == "Darwin" and uname_m == "arm64":
        return ["-accel", "hvf", "-cpu", "host"]
    elif uname_s == "Linux" and uname_m in ("aarch64", "arm64") and os.path.exists("/dev/kvm") and os.access("/dev/kvm", os.R_OK | os.W_OK):
        return ["-enable-kvm", "-cpu", "host"]
    else:
        return ["-cpu", "cortex-a57"]


def optimize_base_set(work_dir: str, res_mgr: ResourceManager):
    """
    Optimizes official base79.tgz atomically:
    - Embeds genuine DM250 custom kernel (/bsd).
    - Neutralizes /usr/libexec/reorder_kernel to strictly prevent automatic kernel relinking.
    - Physically removes /usr/share/relink kit to eliminate any chance of generic kernel overwrite.
    - Uses atomic temporary file replacement to avoid corrupt files on Ctrl+C.
    """
    base_orig = os.path.join(work_dir, "base79.tgz")
    base_opt = os.path.join(work_dir, "base79_opt.tgz")
    base_opt_tmp = os.path.join(work_dir, "base79_opt.tgz.tmp")
    custom_bsd = os.path.join(work_dir, "bsd")

    if not os.path.exists(base_orig):
        raise FileNotFoundError(f"Original base set not found: {base_orig}")
    if not os.path.exists(custom_bsd):
        raise FileNotFoundError(f"DM250 custom kernel not found: {custom_bsd}")

    print(">> [engine] Optimizing base79.tgz (Embedding DM250 kernel & neutralizing reorder_kernel)...")
    with open(custom_bsd, "rb") as f:
        bsd_data = f.read()
    reorder_data = b"#!/bin/sh\nexit 0\n"

    res_mgr.register_temp_file(base_opt_tmp)
    try:
        with tarfile.open(base_orig, "r:gz") as tar_in, tarfile.open(base_opt_tmp, "w:gz") as tar_out:
            for member in tar_in.getmembers():
                if member.name in ("./bsd", "bsd"):
                    tarinfo = tarfile.TarInfo(name=member.name)
                    tarinfo.size = len(bsd_data)
                    tarinfo.mode = 0o755
                    tarinfo.mtime = member.mtime
                    tar_out.addfile(tarinfo, io.BytesIO(bsd_data))
                elif member.name in ("./usr/libexec/reorder_kernel", "usr/libexec/reorder_kernel"):
                    tarinfo = tarfile.TarInfo(name=member.name)
                    tarinfo.size = len(reorder_data)
                    tarinfo.mode = 0o755
                    tarinfo.mtime = member.mtime
                    tar_out.addfile(tarinfo, io.BytesIO(reorder_data))
                elif "usr/share/relink" in member.name:
                    continue
                else:
                    if member.isreg():
                        tar_out.addfile(member, tar_in.extractfile(member))
                    else:
                        tar_out.addfile(member)
        os.replace(base_opt_tmp, base_opt)
    finally:
        res_mgr.unregister_temp_file(base_opt_tmp)
        if os.path.exists(base_opt_tmp):
            try:
                os.remove(base_opt_tmp)
            except Exception:
                pass


def parse_wifi_networks(config_file: str) -> List[Tuple[str, str]]:
    """Parse Wi-Fi SSID and PSK pairs from user config file."""
    wifi_entries = []
    if os.path.exists(config_file):
        with open(config_file, "r") as f:
            in_wifi = False
            for line in f:
                line = line.strip()
                if line.startswith("POMERA_WIFI_NETWORKS="):
                    in_wifi = True
                    val = line.split("=", 1)[1].strip().strip('"\'')
                    if val and ":" in val and not val.startswith("#"):
                        ssid, psk = val.split(":", 1)
                        wifi_entries.append((ssid.strip(), psk.strip()))
                    continue
                if in_wifi:
                    if line.endswith('"') or line.endswith("'"):
                        line = line[:-1].strip()
                        in_wifi = False
                    if ":" in line and not line.startswith("#"):
                        ssid, psk = line.split(":", 1)
                        wifi_entries.append((ssid.strip(), psk.strip()))

    return wifi_entries


def parse_user_config_value(config_file: str, key: str, default: str = "") -> str:
    """Extract single configuration value from user config env file."""
    if os.path.exists(config_file):
        with open(config_file, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith(f"{key}=") or line.startswith(f"export {key}="):
                    val = line.split("=", 1)[1].strip().strip('"\'')
                    return val
    return default


def normalize_tarinfo(tarinfo: tarfile.TarInfo) -> tarfile.TarInfo:
    """Normalize file permissions and ownership for OpenBSD site set extraction."""
    tarinfo.uid = 0
    tarinfo.gid = 0
    tarinfo.uname = "root"
    tarinfo.gname = "wheel"
    if tarinfo.isdir():
        tarinfo.mode = 0o755
    elif tarinfo.name.endswith(".sh") or "bin/" in tarinfo.name or "sbin/" in tarinfo.name or "install.site" in tarinfo.name:
        tarinfo.mode = 0o755
    elif "hostname." in tarinfo.name or "doas.conf" in tarinfo.name:
        tarinfo.mode = 0o600
    else:
        tarinfo.mode = 0o644
    return tarinfo


def package_site_set(work_dir: str, configs_dir: str, scripts_dir: str, res_mgr: ResourceManager):
    """
    Packages site79.tgz atomically with complete out-of-the-box configurations:
    - Multi-SSID Wi-Fi and USB Ethernet profiles (0600 mode)
    - X11 wsfb 1024x600 xorg.conf & JP keyboard wsconsctl.conf
    - doas.conf (0600 mode) & console ttys
    - Helper tools: lid-watch, gui-toggle, desktop setup, bt-pan
    - Firmware NVRAM configuration
    """
    print(">> [engine] Packaging site79.tgz (Complete Out-of-the-Box Setup)...")
    site_build = os.path.join(work_dir, "site_build")
    res_mgr.register_temp_dir(site_build)

    if os.path.exists(site_build):
        shutil.rmtree(site_build, ignore_errors=True)

    os.makedirs(os.path.join(site_build, "usr/local/sbin"), exist_ok=True)
    os.makedirs(os.path.join(site_build, "usr/local/bin"), exist_ok=True)
    os.makedirs(os.path.join(site_build, "etc/firmware"), exist_ok=True)
    os.makedirs(os.path.join(site_build, "etc/X11"), exist_ok=True)

    # 1. Install site scripts
    install_site_src = os.path.join(configs_dir, "install.site")
    subprocess.run(["cp", "-f", install_site_src, os.path.join(site_build, "install.site")], check=True)
    subprocess.run(["chmod", "+x", os.path.join(site_build, "install.site")], check=True)

    # Copy install.site.env from _build_cache or configs
    env_candidate = os.path.join(work_dir, "install.site.env")
    if not os.path.exists(env_candidate):
        env_candidate = os.path.join(configs_dir, "install.site.env")
    if os.path.exists(env_candidate):
        subprocess.run(["cp", "-f", env_candidate, os.path.join(site_build, "install.site.env")], check=True)

    # Copy daemon / CLI helper scripts
    helpers = [
        ("pomera-lid-watch.sh", "usr/local/sbin/pomera-lid-watch", True),
        ("pomera-gui-toggle.sh", "usr/local/bin/pomera-gui-toggle", True),
        ("pomera-setup-desktop.sh", "usr/local/bin/pomera-setup-desktop", True),
        ("pomera-bt-pan.sh", "usr/local/bin/pomera-bt-pan", True),
    ]
    for src_name, dst_rel, make_exec in helpers:
        src_path = os.path.join(scripts_dir, src_name)
        dst_path = os.path.join(site_build, dst_rel)
        subprocess.run(["cp", "-f", src_path, dst_path], check=True)
        if make_exec:
            subprocess.run(["chmod", "+x", dst_path], check=True)

    # 2. Firmware NVRAM text
    nvram_src = os.path.join(configs_dir, "brcmfmac43430-sdio.rockchip,pomera-dm250.txt")
    if os.path.exists(nvram_src):
        subprocess.run(["cp", "-f", nvram_src, os.path.join(site_build, "etc/firmware/brcmfmac43430-sdio.rockchip,pomera-dm250.txt")], check=True)
        subprocess.run(["cp", "-f", nvram_src, os.path.join(site_build, "etc/firmware/brcmfmac43430-sdio.txt")], check=True)

    # Extract official OpenBSD bwfm firmware archive if present
    bwfm_tgz = os.path.join(work_dir, "bwfm-firmware-20200316.1.3p5.tgz")
    if os.path.exists(bwfm_tgz):
        subprocess.run(["tar", "-xzf", bwfm_tgz, "-C", os.path.join(site_build, "etc/firmware")], check=True)

    # 3. System configuration files
    os.makedirs(os.path.join(site_build, "etc/rc.d"), exist_ok=True)
    rc_d_lid = os.path.join(site_build, "etc/rc.d/pomera_lid_watch")
    with open(rc_d_lid, "w") as f:
        f.write("""#!/bin/ksh

daemon="/usr/local/sbin/pomera-lid-watch"

. /etc/rc.d/rc.subr

pexp="/bin/sh ${daemon}.*"
rc_bg=YES
rc_reload=NO

rc_cmd $1
""")
    os.chmod(rc_d_lid, 0o755)

    with open(os.path.join(site_build, "etc/doas.conf"), "w") as f:
        f.write("permit keepenv :wheel\npermit nopass :wheel cmd reboot\npermit nopass :wheel cmd poweroff\n")
    os.chmod(os.path.join(site_build, "etc/doas.conf"), 0o600)

    with open(os.path.join(site_build, "etc/X11/xorg.conf"), "w") as f:
        f.write("""Section "Device"
    Identifier "Card0"
    Driver     "wsfb"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device     "Card0"
    Monitor    "Monitor0"
    DefaultDepth 16
    SubSection "Display"
        Depth 16
        Modes "1024x600"
    EndSubSection
EndSection

Section "Monitor"
    Identifier "Monitor0"
EndSection
""")

    with open(os.path.join(site_build, "etc/wsconsctl.conf"), "w") as f:
        f.write("""keyboard.encoding=jp
keyboard.map+=keycode 13 = asciicircum asciitilde
keyboard.map+=keycode 58 = Control_L
keyboard.map+=keycode 139 = Mode_switch
keyboard.map+=keycode 103 = Up Up Prior Prior
keyboard.map+=keycode 108 = Down Down Next Next
""")

    with open(os.path.join(site_build, "etc/sysctl.conf"), "w") as f:
        f.write("ddb.panic=0\nmachdep.lidaction=0\nhw.setperf=100\n")

    with open(os.path.join(site_build, "etc/boot.conf"), "w") as f:
        f.write("set tty fb0\nset timeout 5\nboot /bsd\n")

    idb_src = os.path.join(work_dir, "idbloader.img")
    if os.path.exists(idb_src):
        os.makedirs(os.path.join(site_build, "usr/mdec"), exist_ok=True)
        shutil.copy2(idb_src, os.path.join(site_build, "usr/mdec/idbloader.img"))
        shutil.copy2(idb_src, os.path.join(site_build, "idbloader.img"))

    uboot_src = os.path.join(work_dir, "uboot.img")
    if os.path.exists(uboot_src):
        os.makedirs(os.path.join(site_build, "usr/mdec"), exist_ok=True)
        shutil.copy2(uboot_src, os.path.join(site_build, "usr/mdec/uboot.img"))
        shutil.copy2(uboot_src, os.path.join(site_build, "uboot.img"))

    with open(os.path.join(site_build, "etc/ttys"), "w") as f:
        f.write("""console	"/usr/libexec/getty std.9600"	wsvt25	on  secure
ttyC0	"/usr/libexec/getty std.9600"	vt220	off secure
ttyC1	"/usr/libexec/getty std.9600"	wsvt25	on  secure
ttyC2	"/usr/libexec/getty std.9600"	wsvt25	on  secure
ttyC3	"/usr/libexec/getty std.9600"	wsvt25	on  secure
ttyC4	"/usr/libexec/getty std.9600"	wsvt25	on  secure
ttyC5	"/usr/libexec/getty std.9600"	wsvt25	on  secure
""")

    # 4. Multi-SSID Wi-Fi & USB Ethernet configuration
    user_config_file = os.path.join(configs_dir, "user_config.env")
    wifi_entries = parse_wifi_networks(user_config_file)

    with open(os.path.join(site_build, "etc/hostname.bwfm0"), "w") as f:
        for ssid, psk in wifi_entries:
            f.write(f'join "{ssid}" wpakey "{psk}"\n')
        f.write("dhcp\n")
    os.chmod(os.path.join(site_build, "etc/hostname.bwfm0"), 0o600)

    for ifname in ("ure0", "axe0", "axen0", "cdce0", "urndis0", "smsc0"):
        hn_path = os.path.join(site_build, f"etc/hostname.{ifname}")
        with open(hn_path, "w") as f:
            f.write("dhcp\n")
        os.chmod(hn_path, 0o600)

    # 5. Archive site79.tgz atomically with normalized root:wheel metadata
    site_tgz_path = os.path.join(work_dir, "site79.tgz")
    site_tgz_tmp = os.path.join(work_dir, "site79.tgz.tmp")
    res_mgr.register_temp_file(site_tgz_tmp)
    try:
        with tarfile.open(site_tgz_tmp, "w:gz") as tar:
            for item in os.listdir(site_build):
                item_path = os.path.join(site_build, item)
                tar.add(item_path, arcname=item, filter=normalize_tarinfo)
        os.replace(site_tgz_tmp, site_tgz_path)
    finally:
        res_mgr.unregister_temp_file(site_tgz_tmp)
        if os.path.exists(site_tgz_tmp):
            try:
                os.remove(site_tgz_tmp)
            except Exception:
                pass

    shutil.rmtree(site_build, ignore_errors=True)
    res_mgr.unregister_temp_dir(site_build)


def sync_distribution_files(work_dir: str, configs_dir: str):
    """Ensure all required installer configs are present in _build_cache for HTTP server."""
    conf_src = os.path.join(work_dir, "install.conf")
    if not os.path.exists(conf_src):
        conf_src = os.path.join(configs_dir, "install.conf")

    for dest_name in ("install.conf", "auto_install.conf", "pomera.conf"):
        dest_path = os.path.join(work_dir, dest_name)
        if conf_src != dest_path:
            subprocess.run(["cp", "-f", conf_src, dest_path], check=True)

    subprocess.run(["cp", "-f", os.path.join(configs_dir, "install.md"), os.path.join(work_dir, "install.md")], check=True)
    nvram = os.path.join(configs_dir, "brcmfmac43430-sdio.rockchip,pomera-dm250.txt")
    if os.path.exists(nvram):
        subprocess.run(["cp", "-f", nvram, os.path.join(work_dir, "brcmfmac43430-sdio.rockchip,pomera-dm250.txt")], check=True)

    # Ensure authentic idbloader.img exists in work_dir
    idbloader_path = os.path.join(work_dir, "idbloader.img")
    ddr_path = os.path.join(work_dir, "rk3128_ddr.bin")
    mini_path = os.path.join(work_dir, "rk312x_miniloader.bin")
    if os.path.exists(ddr_path) and os.path.exists(mini_path):
        if create_idbloader is not None:
            try:
                create_idbloader(ddr_path, mini_path, idbloader_path)
            except Exception as e:
                print(f"⚠️ Warning: Could not generate idbloader.img: {e}")
        else:
            print("⚠️ Warning: create_idbloader module not available, skipping idbloader generation.")

    # Deploy 100% safe non-destructive _sdboot.sh (NEVER overwrites eMMC)
    safe_sdboot_path = os.path.join(work_dir, "_sdboot.sh")
    with open(safe_sdboot_path, "w") as f_boot:
        f_boot.write("""#!/bin/sh
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
""")


CONFIRM_SECTION_TEMPLATE = """
cat << 'EOF_CONFIRM' >> /mnt/etc/rc

# 4. Confirmation Prompt before Erasing Internal Storage
echo "" >/dev/ttyC0
echo "==========================================================" >/dev/ttyC0
echo "  WARNING: ALL DATA ON INTERNAL STORAGE (eMMC)" >/dev/ttyC0
echo "  WILL BE COMPLETELY ERASED!" >/dev/ttyC0
echo "  OpenBSD 7.9 will be installed onto internal storage." >/dev/ttyC0
echo "==========================================================" >/dev/ttyC0
echo -n "Start installation? (yes/N): " >/dev/ttyC0

read -r _ans </dev/ttyC0 || _ans="no"

case "$_ans" in
    yes|YES)
        echo "" >/dev/ttyC0
        echo ">> Confirmation received. Proceeding with installation..." >/dev/ttyC0
        ;;
    *)
        echo "" >/dev/ttyC0
        echo ">> Installation aborted by user." >/dev/ttyC0
        echo "   Internal storage (eMMC) was NOT modified." >/dev/ttyC0
        echo "==========================================================" >/dev/ttyC0
        echo "Select an action:" >/dev/ttyC0
        echo "  (h) Power off / Halt (halt -p) [Default]" >/dev/ttyC0
        echo "  (s) Maintenance Shell" >/dev/ttyC0
        echo "  (r) Reboot" >/dev/ttyC0
        echo -n "Choice [h]: " >/dev/ttyC0
        read -r _post_ans </dev/ttyC0 || _post_ans="h"
        case "$_post_ans" in
            s|S|shell)
                echo "Dropping to maintenance shell. Type 'exit' when done." >/dev/ttyC0
                /bin/sh </dev/ttyC0 >/dev/ttyC0 2>&1
                ;;
            r|R|reboot)
                echo "Rebooting system..." >/dev/ttyC0
                reboot
                exit 0
                ;;
        esac
        echo "Powering off system..." >/dev/ttyC0
        sync
        sync
        halt -p
        exit 0
        ;;
esac
EOF_CONFIRM
"""


def find_prep_template(scripts_dir: str = "", configs_dir: str = "") -> str:
    """Locate the external prep_sd_vm.template.sh template file."""
    search_dirs = [
        scripts_dir,
        configs_dir,
        os.path.dirname(os.path.abspath(__file__)),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "configs"),
    ]
    for d in search_dirs:
        if not d or not os.path.isdir(d):
            continue
        for fname in ("prep_sd_vm.template.sh", "prep_sd_vm.sh.template"):
            candidate = os.path.join(d, fname)
            if os.path.isfile(candidate):
                return candidate
    raise FileNotFoundError(f"prep_sd_vm.template.sh not found in {scripts_dir} or {configs_dir}")


def generate_vm_prep_script(
    work_dir: str,
    http_port: int,
    tool_version: str,
    scripts_dir: str = "",
    configs_dir: str = "",
    confirm_install: bool = True,
    boot_timeout: int = 5,
    template_path: Optional[str] = None,
) -> str:
    """Generate OpenBSD VM guest provisioning script from external template."""
    prep_script_path = os.path.join(work_dir, "prep_sd_vm.sh")

    if template_path is None:
        template_path = find_prep_template(scripts_dir, configs_dir)

    with open(template_path, "r", encoding="utf-8") as tf:
        template_text = tf.read()

    confirm_section = CONFIRM_SECTION_TEMPLATE if confirm_install else ""

    content = (
        template_text
        .replace("@HTTP_PORT@", str(http_port))
        .replace("@TOOL_VERSION@", str(tool_version))
        .replace("@BOOT_TIMEOUT@", str(boot_timeout))
        .replace("@CONFIRM_SECTION@", confirm_section)
    )

    with open(prep_script_path, "w", encoding="utf-8") as f:
        f.write(content)
    return prep_script_path


def flash_target_bootloader(target_path: str, is_raw_device: bool, work_dir: str) -> None:
    """
    Write authentic Rockchip BootROM raw sectors (idbloader at 64, uboot at 16384).
    For disk image files, writes directly via Python file I/O.
    For physical SD block devices, flashing is orchestrated directly by the host shell (make_sdcard.sh).
    """
    if is_raw_device:
        return

    idbloader = os.path.join(work_dir, "idbloader.img")
    uboot = os.path.join(work_dir, "uboot.img")

    if not os.path.exists(idbloader) or not os.path.exists(uboot):
        print(f"⚠️ Warning: Bootloader images missing in {work_dir}, skipping raw sector flash.")
        return

    print(f">> [engine] Writing Rockchip BootROM bootloader sectors (LBA 64 & 16384) to {target_path}...")
    with open(target_path, "r+b") as f_tgt:
        with open(idbloader, "rb") as f_idb:
            f_tgt.seek(64 * 512)
            f_tgt.write(f_idb.read())
        with open(uboot, "rb") as f_ub:
            f_tgt.seek(16384 * 512)
            f_tgt.write(f_ub.read())
    print(">> [engine] ✅ Rockchip raw bootloader written successfully to disk image!")


def run_qemu_builder(
    target_path: str,
    work_dir: str,
    configs_dir: str,
    scripts_dir: str,
    tool_version: str = "79.0",
    is_raw_device: bool = False,
):
    """
    Main builder entry point.
    Executes base optimization, site packaging, VM preparation, and drives
    the throwaway QEMU builder VM with full signal and resource protection.
    """
    res_mgr = ResourceManager(work_dir, configs_dir)

    # 1. Base set optimization (atomic)
    optimize_base_set(work_dir, res_mgr)

    # 2. Package site79.tgz (atomic)
    package_site_set(work_dir, configs_dir, scripts_dir, res_mgr)

    # 3. Synchronize distribution config files
    sync_distribution_files(work_dir, configs_dir)

    # 4. Start HTTP distribution server serving work_dir with dynamic port
    handler = functools.partial(SilentHandler, directory=work_dir)
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    http_port = httpd.server_address[1]

    res_mgr.httpd = httpd
    http_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    http_thread.start()
    print(f">> [engine] Local HTTP distribution server running on 127.0.0.1:{http_port} (serving {work_dir})")

    # 5. Generate VM guest provisioning script with dynamic port and confirmation option
    user_cfg = os.path.join(configs_dir, "user_config.env")
    site_env = os.path.join(work_dir, "install.site.env")
    confirm_val = parse_user_config_value(user_cfg, "POMERA_CONFIRM_INSTALL", default="")
    if not confirm_val:
        confirm_val = parse_user_config_value(site_env, "POMERA_CONFIRM_INSTALL", default="yes")
    confirm_install = confirm_val.lower() != "no"

    timeout_val = parse_user_config_value(user_cfg, "POMERA_BOOT_TIMEOUT", default="")
    if not timeout_val:
        timeout_val = parse_user_config_value(site_env, "POMERA_BOOT_TIMEOUT", default="5")
    try:
        boot_timeout = int(timeout_val)
    except ValueError:
        boot_timeout = 5

    generate_vm_prep_script(
        work_dir,
        http_port,
        tool_version,
        scripts_dir=scripts_dir,
        configs_dir=configs_dir,
        confirm_install=confirm_install,
        boot_timeout=boot_timeout,
    )

    # 6. Locate EDK2 and QEMU acceleration
    edk2_bin = find_edk2_firmware()
    accel_opts = get_qemu_accelerator()
    print(f">> [engine] Using EDK2 Firmware: {edk2_bin}")

    # Unique serial socket path using PID
    serial_sock = f"/tmp/pomera-qemu-serial-{os.getpid()}.sock"
    res_mgr.serial_sock = serial_sock
    if os.path.exists(serial_sock):
        os.remove(serial_sock)

    miniroot_img = os.path.join(work_dir, "miniroot79.img")
    install_img = os.path.join(work_dir, "install79_arm64.img")
    if os.path.exists(miniroot_img):
        builder_img = miniroot_img
        print(f">> [engine] Using lightweight OpenBSD miniroot VM image: {miniroot_img} (43MB)")
    elif os.path.exists(install_img):
        builder_img = install_img
        print(f">> [engine] Using cached OpenBSD install VM image: {install_img} (630MB)")
    else:
        raise FileNotFoundError(f"OpenBSD builder VM image not found (miniroot79.img or install79_arm64.img) in {work_dir}")

    target_drive_opt = f"file={target_path},format=raw,if=virtio"
    if is_raw_device:
        target_drive_opt += ",cache=none"

    qemu_cmd = [
        "qemu-system-aarch64",
        "-M", "virt",
    ] + accel_opts + [
        "-m", "1024M",
        "-smp", "4",
        "-bios", edk2_bin,
        "-drive", f"file={builder_img},format=raw,if=virtio,readonly=on",
        "-drive", target_drive_opt,
        "-netdev", "user,id=net0",
        "-device", "virtio-net,netdev=net0",
        "-display", "none",
        "-serial", f"unix:{serial_sock},server,nowait",
        "-no-reboot",
    ]

    print(f">> [engine] Starting Throwaway OpenBSD VM for target: {target_path}...")

    # Capture QEMU stderr for actionable error diagnosis (PID-specific to avoid permission conflicts)
    qemu_err_log = os.path.join(work_dir, f"qemu_stderr_{os.getpid()}.log")
    res_mgr.register_temp_file(qemu_err_log)
    err_file = open(qemu_err_log, "w")

    res_mgr.qemu_proc = subprocess.Popen(
        qemu_cmd,
        preexec_fn=os.setsid,
        stdout=subprocess.DEVNULL,
        stderr=err_file,
    )

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        # Wait up to 30 seconds for socket creation, with immediate crash detection
        connected = False
        for _ in range(30):
            if res_mgr.done_event.is_set():
                break

            # Fast crash detection: if QEMU exited early, don't wait for socket timeout
            exit_code = res_mgr.qemu_proc.poll()
            if exit_code is not None:
                err_file.flush()
                err_msg = ""
                if os.path.exists(qemu_err_log):
                    with open(qemu_err_log, "r") as ef:
                        err_msg = ef.read().strip()
                raise RuntimeError(
                    f"QEMU process died immediately with code {exit_code}.\n"
                    f"Diagnostics from QEMU:\n{err_msg or '(no stderr output)'}"
                )

            if os.path.exists(serial_sock):
                try:
                    s.connect(serial_sock)
                    connected = True
                    break
                except socket.error:
                    pass
            time.sleep(1)

        if not connected:
            raise TimeoutError("Timeout waiting for QEMU serial socket connection.")

        s.settimeout(1.0)

        buf = bytearray()
        buf_lock = threading.Lock()

        def reader():
            while not res_mgr.done_event.is_set():
                try:
                    data = s.recv(4096)
                    if not data:
                        break
                    with buf_lock:
                        buf.extend(data)
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                except socket.timeout:
                    continue
                except Exception:
                    break

        reader_thread = threading.Thread(target=reader, daemon=True)
        reader_thread.start()

        def expect_any(patterns: List[str], timeout: int = 300) -> str:
            pats = [p.encode() for p in patterns]
            deadline = time.time() + timeout
            while time.time() < deadline:
                if res_mgr.done_event.is_set():
                    raise InterruptedError("Interrupted while waiting for pattern.")
                with buf_lock:
                    for idx, pat in enumerate(pats):
                        pos = buf.find(pat)
                        if pos >= 0:
                            matched = patterns[idx]
                            del buf[: pos + len(pat)]
                            return matched
                time.sleep(0.5)
            raise TimeoutError(f"Timeout ({timeout}s) waiting for any of: {patterns}")

        def expect(pattern: str, timeout: int = 300):
            expect_any([pattern], timeout=timeout)

        def send(cmd: str):
            s.sendall(cmd.encode())

        # Drive VM setup sequence
        print(">> [driver] Waiting for OpenBSD installer welcome prompt...")
        expect("(I)nstall, (U)pgrade, (A)utoinstall or (S)hell?", timeout=300)
        time.sleep(1)
        send("s\n")

        expect("# ", timeout=60)
        print(">> [driver] Configuring DHCP in VM...")
        send("ifconfig vio0 inet autoconf; dhcpleased >/dev/null 2>&1 &\n")
        time.sleep(3)

        expect("# ", timeout=30)
        print(">> [driver] Running native OpenBSD formatting on target storage...")
        send(f"ftp -V -o /tmp/prep.sh http://10.0.2.2:{http_port}/prep_sd_vm.sh\n")

        expect("# ", timeout=60)
        send("sh /tmp/prep.sh\n")

        expect("SD-PREP-COMPLETE", timeout=1200)
        print(">> [driver] Native OpenBSD Formatting & Deployment Complete!")

        # Wait for clean VM halt
        res_mgr.qemu_proc.wait(timeout=60)

        # Flash Rockchip BootROM raw bootloader sectors directly on host
        flash_target_bootloader(target_path, is_raw_device, work_dir)

    except BaseException as e:
        print(f"\n❌ Builder encountered error: {e}", file=sys.stderr)
        res_mgr.cleanup()
        raise
    finally:
        try:
            s.close()
        except Exception:
            pass
        try:
            err_file.close()
        except Exception:
            pass
        res_mgr.cleanup()
