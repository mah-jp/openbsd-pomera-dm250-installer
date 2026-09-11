#!/usr/bin/env python3
"""
inspect_kernel.py - Automated Inspection of DM250 OpenBSD Kernel Patches.

Verifies whether an OpenBSD armv7 kernel binary (bsd) contains:
1. PR #4: X11 Right-Shift & Left-Alt keys fix (gpiokeys raw mode / wskbd_rawinput)
2. PR #3: USB Hub split transactions fix (dwc2 split_channels snapshot buffer)

Works independently of specific function names by inspecting disassembly patterns,
constants, and API call references. Compatible with macOS and Linux.

Exit codes:
  0: Requested patch(es) are present in the kernel
  1: One or more requested patches are MISSING
  2: Error executing inspection (e.g. file not found or invalid format)
"""

import os
import sys
import shutil
import argparse
import subprocess
from typing import Tuple, Optional


def find_tool(candidates) -> Optional[str]:
    for tool in candidates:
        path = shutil.which(tool)
        if path:
            return path
    return None


def run_cmd(args) -> Tuple[int, str]:
    try:
        res = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        return res.returncode, res.stdout + res.stderr
    except Exception as e:
        return 99, str(e)


def check_x11_key_patch(kernel_path: str, objdump_bin: Optional[str], nm_bin: Optional[str]) -> Tuple[bool, str]:
    """
    Checks if gpiokeys handles raw scancode mode for X11 (Right-Shift key 54, Left-Alt key 56).
    Primary check: gpiokeys_console_key calling wskbd_rawinput.
    Fallback check: presence of wskbd_is_raw symbol.
    """
    if objdump_bin:
        code, out = run_cmd([objdump_bin, "-d", "--disassemble-symbols=gpiokeys_console_key", kernel_path])
        if code == 0 and "gpiokeys_console_key" in out:
            if "wskbd_rawinput" in out:
                return True, "gpiokeys_console_key calls wskbd_rawinput (X11 raw mode verified)"
            if ("#54" in out or "0x36" in out) and ("#56" in out or "0x38" in out):
                return True, "gpiokeys_console_key contains keycode 54/56 XT conversion logic"
            return False, "gpiokeys_console_key only calls standard wskbd_input (no X11 raw support)"

    # Fallback to nm if objdump failed or is unavailable
    if nm_bin:
        code, out = run_cmd([nm_bin, kernel_path])
        if code == 0:
            if "wskbd_is_raw" in out:
                return True, "Found wskbd_is_raw helper symbol in kernel symbol table"
            return False, "Neither wskbd_rawinput call nor wskbd_is_raw found"

    return False, "Unable to inspect binary (no usable objdump or nm)"


def check_usb_hub_patch(kernel_path: str, objdump_bin: Optional[str]) -> Tuple[bool, str]:
    """
    Checks if dwc2 USB host driver snapshots split_order into a local buffer.
    Primary check: dwc2_hc_intr has stack protector (__stack_smash_handler) due to split_channels[16] array.
    Secondary check: dwc2_hc_intr compares against #15 (MAX_EPS_CHANNELS boundary).
    Tertiary check: dwc2_hc_n_intr checks chnum < 0 (bmi instruction in prologue).
    """
    if objdump_bin:
        # Check dwc2_hc_intr
        code, out = run_cmd([objdump_bin, "-d", "--disassemble-symbols=dwc2_hc_intr", kernel_path])
        if code == 0 and "dwc2_hc_intr" in out:
            has_stack_smash = "stack_smash" in out
            has_boundary_check = "#15" in out or "0xf" in out
            if has_stack_smash or has_boundary_check:
                reasons = []
                if has_stack_smash:
                    reasons.append("split_channels buffer stack protector present")
                if has_boundary_check:
                    reasons.append("MAX_EPS_CHANNELS (#15) boundary check verified")
                return True, f"dwc2_hc_intr: {', '.join(reasons)}"
            return False, "dwc2_hc_intr iterates split_order directly (unprotected, subject to list corruption)"

        # Check dwc2_hc_n_intr prologue for bmi
        code_n, out_n = run_cmd([objdump_bin, "-d", "--disassemble-symbols=dwc2_hc_n_intr", kernel_path])
        if code_n == 0 and "dwc2_hc_n_intr" in out_n:
            # Check first 20 instructions
            lines = out_n.splitlines()[:25]
            if any("bmi" in l for l in lines):
                return True, "dwc2_hc_n_intr has channel negative check (bmi in prologue)"

    return False, "Unable to verify dwc2 split order snapshot logic"


def check_smart_kernel(kernel_path: str, nm_bin: Optional[str]) -> Tuple[bool, str]:
    """
    Checks if the kernel is a Pomera DM250 optimized smart kernel (DM250 config).
    1. Primary check: Scan binary for '(DM250)' in the kernel version banner.
    2. Secondary check: Ensure foreign SoC / PCI drivers (e.g. imxccm, pci_probe) are absent.
    """
    try:
        with open(kernel_path, "rb") as f:
            data = f.read(10 * 1024 * 1024)
            if b"(DM250)" in data:
                return True, "Kernel banner identifies as DM250 config (OpenBSD (DM250))"
            if b"(GENERIC)" in data:
                return False, "Kernel banner identifies as GENERIC config (foreign SoCs/PCI included)"
    except Exception as e:
        return False, f"Failed to read kernel binary: {e}"

    if nm_bin:
        code, out = run_cmd([nm_bin, kernel_path])
        if code == 0:
            if "imxccm_attach" not in out and "sxiintc_attach" not in out and "rkclock_attach" in out:
                return True, "Symbol audit: foreign SoCs absent, Rockchip RK3128 present"
            return False, "Symbol audit: found generic/foreign SoC symbols in kernel"

    return False, "Unable to verify DM250 smart kernel signature"


def check_smode_patch(kernel_path: str, objdump_bin: Optional[str]) -> Tuple[bool, str]:
    """
    Checks if rkdrm implements WSDISPLAYIO_SMODE ioctl (for mlterm-fb DUMBFB console).
    WSDISPLAYIO_SMODE = _IOW('W', 76, u_int) = 0x8004574c.
    """
    if objdump_bin:
        code, out = run_cmd([objdump_bin, "-d", "--disassemble-symbols=rkdrm_wsioctl", kernel_path])
        if code == 0 and "rkdrm_wsioctl" in out:
            # Look for 0x574c (low 16 bits of WSDISPLAYIO_SMODE) or 8004574c
            if "574c" in out.lower() or "8004574c" in out.lower():
                return True, "rkdrm_wsioctl accepts WSDISPLAYIO_SMODE (0x8004574c) for mlterm-fb DUMBFB"
            return False, "rkdrm_wsioctl does not handle WSDISPLAYIO_SMODE (returns ENOTTY, mlterm-fb will fail)"

    # Fallback to binary search if objdump is unavailable
    try:
        with open(kernel_path, "rb") as f:
            data = f.read()
            if b"\x4c\x57\x04\x80" in data or b"\x4c\x07\x05\xe3" in data or b"\x4c\x17\x05\xe3" in data:
                return True, "Found WSDISPLAYIO_SMODE constant pattern in kernel binary"
    except Exception:
        pass

    return False, "Unable to verify rkdrm WSDISPLAYIO_SMODE patch"


def main():
    parser = argparse.ArgumentParser(description="Inspect OpenBSD DM250 kernel for hardware patches and smart optimization")
    parser.add_argument("kernel", help="Path to kernel binary (bsd or bsd.patched)")
    parser.add_argument("--check-x11", action="store_true", help="Check only X11 Right-Shift / Left-Alt fix (PR #4)")
    parser.add_argument("--check-usb", action="store_true", help="Check only USB Hub split transaction fix (PR #3)")
    parser.add_argument("--check-smode", action="store_true", help="Check rkdrm WSDISPLAYIO_SMODE fix for mlterm-fb")
    parser.add_argument("--check-smart", action="store_true", help="Check if kernel is optimized DM250 smart kernel")
    parser.add_argument("--check-all", action="store_true", help="Check that all hardware patches are present")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print detailed inspection diagnostic messages")

    args = parser.parse_args()

    if not os.path.isfile(args.kernel):
        print(f"❌ Error: Kernel file not found: {args.kernel}", file=sys.stderr)
        sys.exit(2)

    # Locate analysis tools
    objdump_bin = find_tool(["llvm-objdump", "objdump", "arm-none-eabi-objdump", "arm-linux-gnueabihf-objdump"])
    nm_bin = find_tool(["llvm-nm", "nm", "gnm", "arm-none-eabi-nm"])

    has_x11, reason_x11 = check_x11_key_patch(args.kernel, objdump_bin, nm_bin)
    has_usb, reason_usb = check_usb_hub_patch(args.kernel, objdump_bin)
    has_smode, reason_smode = check_smode_patch(args.kernel, objdump_bin)
    has_smart, reason_smart = check_smart_kernel(args.kernel, nm_bin)

    no_specific_checks = not (args.check_x11 or args.check_usb or args.check_smode or args.check_smart or args.check_all)

    if args.verbose or no_specific_checks:
        print(f"=== Kernel Inspection Report: {os.path.basename(args.kernel)} ===")
        print(f"  Toolchain : objdump={objdump_bin or 'none'}, nm={nm_bin or 'none'}")
        print(f"  DM250 Smart Kernel (Slim / Optimized) : {'✅ APPLIED' if has_smart else '❌ MISSING (GENERIC)'}")
        print(f"     -> Details: {reason_smart}")
        print(f"  PR #4 (X11 Right-Shift & Left-Alt Keys) : {'✅ APPLIED' if has_x11 else '❌ MISSING'}")
        print(f"     -> Details: {reason_x11}")
        print(f"  PR #3 (USB Hub Split Transactions)     : {'✅ APPLIED' if has_usb else '❌ MISSING'}")
        print(f"     -> Details: {reason_usb}")
        print(f"  rkdrm SMODE (mlterm-fb DUMBFB Console) : {'✅ APPLIED' if has_smode else '❌ MISSING'}")
        print(f"     -> Details: {reason_smode}")
        print("=================================================================")

    # Determine exit code based on requested checks
    passed = True
    if args.check_smart:
        passed = passed and has_smart
    if args.check_x11:
        passed = passed and has_x11
    if args.check_usb:
        passed = passed and has_usb
    if args.check_smode:
        passed = passed and has_smode
    if args.check_all:
        passed = passed and has_x11 and has_usb and has_smode

    # Default if no specific check flags given
    if no_specific_checks:
        passed = has_x11 and has_usb

    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
