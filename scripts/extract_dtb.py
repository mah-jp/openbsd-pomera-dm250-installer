#!/usr/bin/env python3
"""
extract_dtb.py - Extract pure untouched Pomera DM250 DTB from jcs uboot.img binary.
Device Tree & custom U-Boot for Pomera DM250 created by Joshua Stein (jcs): https://jcs.org/dm250

Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
SPDX-License-Identifier: MIT
"""

import sys
import os
import struct

FDT_MAGIC = 0xD00DFEED

def extract_raw_dtb(uboot_path, out_dtb_path):
    print(f">> [extract_dtb] Extracting authentic Pomera DM250 DTB from {uboot_path}...")
    with open(uboot_path, "rb") as f:
        u = f.read()

    pos = 0
    dtb_found = None
    while True:
        idx = u.find(b"\xd0\x0d\xfe\xed", pos)
        if idx == -1:
            break
        fdt_size = struct.unpack(">I", u[idx+4 : idx+8])[0]
        if fdt_size < 100000:
            blob = u[idx : idx + fdt_size]
            if b"Pomera DM250" in blob or b"pomera-dm250" in blob:
                dtb_found = blob
                break
        pos = idx + 1

    if not dtb_found:
        print("❌ Error: Could not find Pomera DM250 DTB in uboot.img")
        sys.exit(1)

    with open(out_dtb_path, "wb") as f:
        f.write(dtb_found)
    print(f"✅ Extracted authentic Pomera DM250 DTB: {out_dtb_path} ({len(dtb_found)} bytes)")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: extract_dtb.py <uboot.img> <output.dtb>")
        sys.exit(1)
    extract_raw_dtb(sys.argv[1], sys.argv[2])
