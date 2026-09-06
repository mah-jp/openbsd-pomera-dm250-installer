#!/usr/bin/env python3
"""
make_idbloader.py - Build Rockchip RK3128 idbloader.img (DDR Init + Miniloader) in pure Python.

Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
SPDX-License-Identifier: MIT
"""

import sys
import os
import struct

# Rockchip BootROM hardware constants
RC4_KEY = b"\x7C\x4E\x03\x04\x55\x05\x09\x07\x2D\x2C\x7B\x38\x17\x0D\x17\x11"
RK_MAGIC = 0x0FF0AA55
RK_BLK_SIZE = 512
RK_SIZE_ALIGN = 2048
RK_INIT_OFFSET = 4  # 4 blocks of 512 bytes = 2048 bytes header size


def rc4_crypt(data: bytes, key: bytes) -> bytes:
    """Standard RC4 encryption/decryption."""
    S = list(range(256))
    j = 0
    for i in range(256):
        j = (j + S[i] + key[i % len(key)]) % 256
        S[i], S[j] = S[j], S[i]
    i = 0
    j = 0
    out = bytearray(len(data))
    for x in range(len(data)):
        i = (i + 1) % 256
        j = (j + S[i]) % 256
        S[i], S[j] = S[j], S[i]
        K = S[(S[i] + S[j]) % 256]
        out[x] = data[x] ^ K
    return bytes(out)


def round_up(val: int, align: int) -> int:
    rem = val % align
    return val if rem == 0 else val + (align - rem)


def create_idbloader(ddr_bin_path: str, miniloader_bin_path: str, output_path: str) -> None:
    """
    Build authentic Rockchip RK3128 idbloader.img matching U-Boot mkimage:
        mkimage -n rk3128 -T rksd -d rk3128_ddr.bin:rk312x_miniloader.bin idbloader.img

    Binary layout:
    - [0x0000..0x01FF] (512 bytes): header0_info (RC4 encrypted with hardware key)
    - [0x0200..0x07FF] (1536 bytes): zero padding to reach RK_INIT_OFFSET * 512 = 2048 bytes
    - [0x0800..] (aligned to 2048B): DDR Init binary (starts with b"RK31", unencrypted)
    - [0x0800+init_size..] (aligned to 2048B): Miniloader binary (unencrypted)
    - Padded to 512-byte sector multiple for raw DMA direct I/O.
    """
    with open(ddr_bin_path, "rb") as f:
        ddr_data = f.read()
    with open(miniloader_bin_path, "rb") as f:
        mini_data = f.read()

    init_size = round_up(len(ddr_data), RK_SIZE_ALIGN)
    boot_size = round_up(len(mini_data), RK_SIZE_ALIGN)
    init_boot_size = init_size + boot_size

    # Build 512-byte header0_info struct
    # struct header0_info {
    #     uint32_t magic;          // 0x0ff0aa55 (offset 0)
    #     uint8_t reserved[4];     // 0 (offset 4)
    #     uint32_t disable_rc4;    // 1 (offset 8) - disable RC4 for RK3128 SPL
    #     uint16_t init_offset;    // 4 (offset 12) - offset in 512B blocks
    #     uint8_t reserved1[492];  // 0 (offset 14..505)
    #     uint16_t init_size;      // init_size // 512 (offset 506..507)
    #     uint16_t init_boot_size; // init_boot_size // 512 (offset 508..509)
    #     uint8_t reserved2[2];    // 0 (offset 510..511)
    # };
    header0 = bytearray(RK_BLK_SIZE)
    struct.pack_into("<I", header0, 0, RK_MAGIC)
    struct.pack_into("<I", header0, 8, 1)  # disable_rc4 = 1
    struct.pack_into("<H", header0, 12, RK_INIT_OFFSET)
    struct.pack_into("<H", header0, 506, init_size // RK_BLK_SIZE)
    struct.pack_into("<H", header0, 508, init_boot_size // RK_BLK_SIZE)

    # Encode ONLY the first 512 bytes with the hardware RC4 key
    enc_header0 = rc4_crypt(bytes(header0), RC4_KEY)

    # Build full 2048-byte header: 512 bytes encoded header0 + 1536 bytes zero padding
    full_header = bytearray(RK_INIT_OFFSET * RK_BLK_SIZE)
    full_header[0:RK_BLK_SIZE] = enc_header0

    # Assemble idbloader
    idbloader = bytearray(full_header)

    # Append DDR init padded to 2048 bytes
    idbloader.extend(ddr_data)
    idbloader.extend(b"\x00" * (init_size - len(ddr_data)))

    # Ensure magic at offset 2048 is "RK31"
    idbloader[2048:2052] = b"RK31"

    # Append Miniloader padded to 2048 bytes
    idbloader.extend(mini_data)
    idbloader.extend(b"\x00" * (boot_size - len(mini_data)))

    # Ensure multiple of 512 bytes for direct DMA I/O
    pad_512 = (512 - (len(idbloader) % 512)) % 512
    if pad_512:
        idbloader.extend(b"\x00" * pad_512)

    with open(output_path, "wb") as f:
        f.write(idbloader)

    print(f"✅ Generated authentic Rockchip idbloader.img: {output_path} ({len(idbloader)} bytes, {len(idbloader)//512} sectors)")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: make_idbloader.py <ddr.bin> <miniloader.bin> <output_idbloader.img>")
        sys.exit(1)
    create_idbloader(sys.argv[1], sys.argv[2], sys.argv[3])
