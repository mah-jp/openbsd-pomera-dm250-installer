#!/usr/bin/env python3
"""
inspect_sd.py - SD Card / Image Physical Sector Inspector.
Inspects MBR partitions, Rockchip BootROM raw sectors (LBA 64 & 16384),
U-Boot embedded bootcmd, and OpenBSD Partition 4 Disklabel magic & checksum.

Usage:
    python3 scripts/inspect_sd.py _build_cache/virtual_emmc.img
    sudo python3 scripts/inspect_sd.py /dev/rdiskN
"""

import sys
import os
import struct

if len(sys.argv) < 2:
    print("Usage: python3 scripts/inspect_sd.py <target_device_or_image>")
    print("Example (Device): sudo python3 scripts/inspect_sd.py /dev/rdisk4")
    print("Example (Image) : python3 scripts/inspect_sd.py _build_cache/virtual_emmc.img")
    sys.exit(1)

target = sys.argv[1]
print(f"=== Inspecting Target: {target} ===")

try:
    with open(target, "rb") as f:
        # 1. Sector 0 (MBR)
        mbr = f.read(512)
        print("\n[Sector 0: MBR]")
        p4_start = 0
        for i in range(4):
            entry = mbr[446 + i * 16 : 446 + (i + 1) * 16]
            status = entry[0]
            ptype = entry[4]
            start = struct.unpack("<I", entry[8:12])[0]
            sectors = struct.unpack("<I", entry[12:16])[0]
            active_str = " (Active/Bootable)" if status == 0x80 else ""
            print(f"  Partition {i+1}: status=0x{status:02X}{active_str}, type=0x{ptype:02X}, start={start} ({start*512//1024//1024}MB), sectors={sectors}")
            if i == 3:
                p4_start = start

        # 2. Sector 64 (idbloader.img)
        f.seek(64 * 512)
        s64 = f.read(512)
        rc4_key = b"\x7C\x4E\x03\x04\x55\x05\x09\x07\x2D\x2C\x7B\x38\x17\x0D\x17\x11"
        S = list(range(256))
        j = 0
        for i in range(256):
            j = (j + S[i] + rc4_key[i % len(rc4_key)]) % 256
            S[i], S[j] = S[j], S[i]
        i = j = 0
        dec_s64 = bytearray(512)
        for x in range(512):
            i = (i + 1) % 256
            j = (j + S[i]) % 256
            S[i], S[j] = S[j], S[i]
            K = S[(S[i] + S[j]) % 256]
            dec_s64[x] = s64[x] ^ K
        magic64 = struct.unpack_from("<I", dec_s64, 0)[0]
        f.seek(68 * 512)
        s68_magic = f.read(4)
        print(f"\n[Sector 64: idbloader.img (Rockchip BootROM Miniloader)]")
        print(f"  Raw bytes          : {s64[:16].hex()}")
        print(f"  RC4 Decrypted Magic: 0x{magic64:08X} (Expected: 0x0FF0AA55)")
        print(f"  Sector 68 Magic    : {s68_magic} (Expected: b'RK31')")
        if magic64 == 0x0FF0AA55 and s68_magic == b"RK31":
            print("  -> ✅ idbloader is PROPERLY WRITTEN at Sector 64!")
        else:
            print("  -> ❌ idbloader is MISSING or CORRUPTED at Sector 64!")

        # 3. Sector 16384 (uboot.img)
        f.seek(16384 * 512)
        s16384 = f.read(512)
        magic_uboot = s16384[:8]
        print(f"\n[Sector 16384: uboot.img (Custom U-Boot Loader)]")
        print(f"  Header Magic: {magic_uboot} (Expected: b'LOADER  ')")
        
        # Read next 2MB to find bootcmd
        f.seek(16384 * 512)
        ub_data = f.read(2 * 1024 * 1024)
        idx = ub_data.find(b"bootcmd=")
        if idx != -1:
            end = ub_data.find(b"\x00", idx)
            bootcmd = ub_data[idx:end].decode("ascii", errors="ignore")
            print(f"  Found bootcmd: {bootcmd}")
            if "load mmc 1:1" in bootcmd and "load mmc 0:1" in bootcmd:
                print("  -> ✅ Custom Auto-Boot U-Boot (SD + eMMC Fallback) is PROPERLY WRITTEN!")
            elif "load mmc 1:1" in bootcmd:
                print("  -> ✅ Custom Auto-Boot U-Boot is PROPERLY WRITTEN at Sector 16384!")
            elif "bootefi bootmgr" in bootcmd:
                print("  -> ⚠️ Legacy U-Boot (without auto-boot) is written at Sector 16384!")
        else:
            print("  -> ❌ No U-Boot environment / bootcmd found in Sector 16384!")

        if magic_uboot == b"LOADER  ":
            print("  -> ✅ U-Boot Loader Magic is VALID!")
        else:
            print("  -> ❌ U-Boot Loader Magic is INVALID!")

        # 4. Partition 4 OpenBSD Disklabel Check
        if p4_start > 0:
            print(f"\n[Partition 4: OpenBSD FFS & Disklabel (LBA {p4_start})]")
            f.seek((p4_start + 1) * 512)
            dl_buf = f.read(512)
            if len(dl_buf) == 512:
                magic_dl = struct.unpack_from("<I", dl_buf, 0)[0]
                magic_expected = 0x82564557
                # Compute 16-bit XOR checksum
                words = struct.unpack("<256H", dl_buf)
                checksum = 0
                for w in words:
                    checksum ^= w
                print(f"  Sector 1 Magic   : 0x{magic_dl:08X} (Expected: 0x{magic_expected:08X})")
                print(f"  XOR Checksum     : 0x{checksum:04X} (Expected: 0x0000)")
                if magic_dl == magic_expected and checksum == 0:
                    print("  -> ✅ OpenBSD Native Disklabel is 100% VALID and Verified!")
                elif magic_dl == magic_expected:
                    print("  -> ⚠️ Disklabel Magic valid, but checksum mismatch (checksum=0x%04X)" % checksum)
                else:
                    print("  -> ℹ️ No OpenBSD disklabel detected at Partition 4 Sector 1 (not yet formatted)")

except PermissionError:
    print(f"\n❌ Permission denied opening {target}.")
    print(f"   Please re-run with sudo: sudo python3 dev/scripts/inspect_sd.py {target}")
    sys.exit(1)
except Exception as e:
    print(f"\n❌ Error reading {target}: {e}")
    sys.exit(1)
