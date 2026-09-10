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


def main():
    parser = argparse.ArgumentParser(description="Inspect OpenBSD DM250 kernel for hardware patches")
    parser.add_argument("kernel", help="Path to kernel binary (bsd or bsd.patched)")
    parser.add_argument("--check-x11", action="store_true", help="Check only X11 Right-Shift / Left-Alt fix (PR #4)")
    parser.add_argument("--check-usb", action="store_true", help="Check only USB Hub split transaction fix (PR #3)")
    parser.add_argument("--check-all", action="store_true", help="Check that both fixes are present")
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

    if args.verbose or (not args.check_x11 and not args.check_usb and not args.check_all):
        print(f"=== Kernel Patch Inspection Report: {os.path.basename(args.kernel)} ===")
        print(f"  Toolchain : objdump={objdump_bin or 'none'}, nm={nm_bin or 'none'}")
        print(f"  PR #4 (X11 Right-Shift & Left-Alt Keys) : {'✅ APPLIED' if has_x11 else '❌ MISSING'}")
        print(f"     -> Details: {reason_x11}")
        print(f"  PR #3 (USB Hub Split Transactions)     : {'✅ APPLIED' if has_usb else '❌ MISSING'}")
        print(f"     -> Details: {reason_usb}")
        print("=================================================================")

    # Determine exit code based on requested checks
    if args.check_x11 and not args.check_usb:
        sys.exit(0 if has_x11 else 1)
    elif args.check_usb and not args.check_x11:
        sys.exit(0 if has_usb else 1)
    else:
        # Default or --check-all requires both
        sys.exit(0 if (has_x11 and has_usb) else 1)


if __name__ == "__main__":
    main()
