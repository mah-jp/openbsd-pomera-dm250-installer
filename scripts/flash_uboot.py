#!/usr/bin/env python3
"""
flash_uboot.py - Safe Sector 16384 U-Boot Flasher.

Directly flashes custom auto-boot U-Boot (_build_cache/uboot.img) to Sector 16384
of a target SD card or image, unmounting volumes cleanly and verifying readback.

Usage:
    sudo python3 scripts/flash_uboot.py /dev/rdisk4
"""

import os
import sys
import subprocess
import platform

def main():
    if len(sys.argv) < 2:
        print(f"Usage: sudo {sys.executable} scripts/flash_uboot.py /dev/rdiskN")
        sys.exit(1)

    target = sys.argv[1]
    is_raw_dev = target.startswith("/dev/")

    if is_raw_dev and os.geteuid() != 0:
        print("❌ Error: This script must be run with sudo to write to raw disk devices.")
        print(f"Usage: sudo {sys.executable} scripts/flash_uboot.py {target}")
        sys.exit(1)

    disk_target = target.replace("/dev/rdisk", "/dev/disk")

    # Locate uboot.img at project root _build_cache
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    uboot_img = os.path.join(project_root, "_build_cache", "uboot.img")

    if not os.path.exists(uboot_img):
        print(f"❌ Error: uboot.img not found at {uboot_img}")
        sys.exit(1)

    with open(uboot_img, "rb") as f:
        uboot_data = f.read()

    if len(uboot_data) == 0 or uboot_data[:8] != b'LOADER  ':
        print(f"❌ Error: Invalid uboot.img (Magic: {uboot_data[:8]})")
        sys.exit(1)

    print(f"=== Flashing Auto-Boot U-Boot to {target} ===")
    print(f"Image Source : {uboot_img} ({len(uboot_data)} bytes / {len(uboot_data)//512} sectors)")
    print(f"Target Device: {target} (Sector 16384)")

    # 1. Unmount disk on macOS if raw device
    if is_raw_dev and platform.system() == "Darwin":
        print(f">> Unmounting {disk_target}...")
        subprocess.run(["diskutil", "unmountDisk", disk_target], check=False)

    # 2. Write to sector 16384
    print(">> Writing U-Boot to Sector 16384...")
    with open(target, "r+b") as f:
        f.seek(16384 * 512)
        f.write(uboot_data)
        f.flush()
        os.fsync(f.fileno())

    # 3. Read back and verify
    print(">> Verifying written sectors...")
    with open(target, "rb") as f:
        f.seek(16384 * 512)
        readback = f.read(len(uboot_data))

    if readback != uboot_data:
        print("❌ Verification FAILED! Written data does not match source image.")
        sys.exit(1)

    # Check bootcmd in readback
    idx = readback.find(b'bootcmd=')
    if idx != -1:
        end = readback.find(b'\x00', idx)
        bootcmd_str = readback[idx:end].decode('ascii', errors='ignore')
        print(f"✅ Verified bootcmd: {bootcmd_str}")

    print("🎉 SUCCESS! Auto-Boot U-Boot successfully flashed and verified!")

if __name__ == "__main__":
    main()
