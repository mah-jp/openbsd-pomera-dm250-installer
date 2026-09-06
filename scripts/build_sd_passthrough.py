#!/usr/bin/env python3
"""
build_sd_passthrough.py - Native OpenBSD SD Formatter & Deployer via Throwaway QEMU VM.
Thin CLI entrypoint delegating to robust sd_builder_engine with full signal protection.

Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
SPDX-License-Identifier: MIT
"""

import os
import sys
from sd_builder_engine import run_qemu_builder

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.dirname(SCRIPT_DIR)
WORK_DIR = os.path.join(BASE_DIR, "_build_cache")
CONFIGS_DIR = os.path.join(BASE_DIR, "configs")
SCRIPTS_DIR = os.path.join(BASE_DIR, "scripts")

if len(sys.argv) < 2:
    print("Usage: build_sd_passthrough.py <target_device_or_image> [tool_version]")
    sys.exit(1)

TARGET_DEV = sys.argv[1]
TOOL_VERSION = sys.argv[2] if len(sys.argv) > 2 else "79.0"
IS_RAW_DEV = TARGET_DEV.startswith("/dev/")

print(f">> [build_sd_passthrough] Initializing Native OpenBSD SD builder v{TOOL_VERSION}...")
print(f"   Target: {TARGET_DEV} (Raw Device: {IS_RAW_DEV})")

try:
    run_qemu_builder(
        target_path=TARGET_DEV,
        work_dir=WORK_DIR,
        configs_dir=CONFIGS_DIR,
        scripts_dir=SCRIPTS_DIR,
        tool_version=TOOL_VERSION,
        is_raw_device=IS_RAW_DEV,
    )
    print(f"\n🎉 [SUCCESS] Native OpenBSD SD Card Prepared Successfully on {TARGET_DEV}!")
except BaseException as e:
    print(f"\n❌ [ABORTED] SD build was interrupted or failed: {e}", file=sys.stderr)
    sys.exit(1)
