#!/usr/bin/env python3
"""
fetch_packages.py - Automated OpenBSD Package Dependency Resolver & Downloader.

Recursively resolves and downloads OpenBSD arm packages for offline installation
on Pomera DM250 into _build_cache/packages.

Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
SPDX-License-Identifier: MIT
"""

import os
import sys
import re
import io
import zlib
import urllib.request
import argparse
from typing import Dict, List, Set

MIRROR_URL = "https://cdn.openbsd.org/pub/OpenBSD/7.9/packages/arm/"
DEFAULT_TARGETS = ["vim", "curl", "git", "mlterm", "noto-cjk", "dmenu"]


def fetch_index(mirror: str) -> Dict[str, int]:
    url = mirror + "index.txt"
    req = urllib.request.Request(url, headers={"User-Agent": "OpenBSD-Pomera-Installer"})
    with urllib.request.urlopen(req) as resp:
        data = resp.read().decode("utf-8", errors="ignore")

    pkgs = {}
    for line in data.splitlines():
        parts = line.split()
        if len(parts) >= 9:
            fname = parts[-1]
            try:
                size = int(parts[4])
                pkgs[fname] = size
            except ValueError:
                pass
    return pkgs


def find_latest_package(prefix: str, all_pkgs: Dict[str, int]) -> str:
    # Prefer standard flavor over gtk/python/lua flavors for base tools like vim
    candidates = [k for k in all_pkgs if re.match(r"^" + re.escape(prefix) + r"-[0-9]", k)]
    if not candidates:
        # Exact stem check
        candidates = [k for k in all_pkgs if k.startswith(prefix + "-")]
    if not candidates:
        raise ValueError(f"No package found matching prefix '{prefix}'")

    unflavored = [c for c in candidates if not any(x in c for x in ["-gtk", "-python", "-lua", "-ruby", "-perl"])]
    pool = unflavored if unflavored else candidates
    return sorted(pool)[-1]


def extract_package_dependencies(mirror: str, pkg_filename: str) -> List[str]:
    url = mirror + pkg_filename
    # Fetch first 256KB where +CONTENTS is located
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "OpenBSD-Pomera-Installer", "Range": "bytes=0-262143"}
    )
    try:
        with urllib.request.urlopen(req) as resp:
            chunk = resp.read()
    except Exception as e:
        print(f"⚠️ Warning: Could not range-read {pkg_filename}: {e}", file=sys.stderr)
        return []

    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        decomp = d.decompress(chunk)
    except Exception:
        decomp = d.unused_data

    buf = io.BytesIO(decomp)
    deps = []
    while True:
        hdr = buf.read(512)
        if len(hdr) < 512 or hdr[:5] == b"\x00" * 5:
            break
        name = hdr[:100].decode("utf-8", errors="ignore").rstrip("\x00")
        size_str = hdr[124:136].decode("utf-8", errors="ignore").strip("\x00").strip()
        size = int(size_str, 8) if size_str else 0
        content = buf.read(size)
        pad = (512 - (size % 512)) % 512
        buf.read(pad)

        if name == "+CONTENTS":
            lines = content.decode("utf-8", errors="ignore").splitlines()
            for line in lines:
                if line.startswith("@depend"):
                    dep_name = line.split(":")[-1].strip()
                    if dep_name:
                        deps.append(dep_name + ".tgz")
            break
    return deps


def resolve_all_dependencies(targets: List[str], mirror: str, all_pkgs: Dict[str, int]) -> Set[str]:
    needed: Set[str] = set()
    queue: List[str] = []

    for t in targets:
        best = find_latest_package(t, all_pkgs)
        needed.add(best)
        queue.append(best)

    processed: Set[str] = set()

    print(">> Resolving package dependency graph...")
    while queue:
        current = queue.pop(0)
        if current in processed:
            continue
        processed.add(current)

        deps = extract_package_dependencies(mirror, current)
        for d in deps:
            # Match against all_pkgs (sometimes exact version differ slightly)
            actual = None
            if d in all_pkgs:
                actual = d
            else:
                stem = re.sub(r"-[0-9].*$", "", d)
                candidates = [k for k in all_pkgs if k.startswith(stem + "-")]
                if candidates:
                    actual = sorted(candidates)[-1]

            if actual and actual not in needed:
                needed.add(actual)
                queue.append(actual)
                print(f"   [dep] {current} -> {actual}")

    return needed


def download_packages(pkgs: Set[str], mirror: str, dest_dir: str, dry_run: bool = False):
    os.makedirs(dest_dir, exist_ok=True)
    total_size = sum(download_packages.all_pkgs.get(p, 0) for p in pkgs)

    print(f"\n>> Total Packages to bundle: {len(pkgs)} ({total_size / 1024 / 1024:.1f} MB)")
    for p in sorted(pkgs):
        sz = download_packages.all_pkgs.get(p, 0) / 1024 / 1024
        dest = os.path.join(dest_dir, p)
        cached = " (CACHED)" if os.path.isfile(dest) else ""
        print(f"   - {p:<40} {sz:>6.2f} MB{cached}")

    if dry_run:
        print("\nDry-run mode: skipping download.")
        return

    print(f"\n>> Downloading packages to {dest_dir}...")
    for idx, p in enumerate(sorted(pkgs), 1):
        dest = os.path.join(dest_dir, p)
        if os.path.isfile(dest) and os.path.getsize(dest) == download_packages.all_pkgs.get(p, 0):
            continue

        url = mirror + p
        print(f"   [{idx}/{len(pkgs)}] Downloading {p}...")
        temp_dest = dest + ".tmp"
        req = urllib.request.Request(url, headers={"User-Agent": "OpenBSD-Pomera-Installer"})
        with urllib.request.urlopen(req) as resp, open(temp_dest, "wb") as out:
            while True:
                buf = resp.read(65536)
                if not buf:
                    break
                out.write(buf)
        os.rename(temp_dest, dest)

    print("✅ All offline packages successfully downloaded and cached.")


def main():
    parser = argparse.ArgumentParser(description="Fetch and cache OpenBSD offline packages for Pomera DM250")
    parser.add_argument("--dest", default="_build_cache/packages", help="Destination cache directory")
    parser.add_argument("--mirror", default=MIRROR_URL, help="OpenBSD packages mirror URL")
    parser.add_argument("--targets", nargs="+", default=DEFAULT_TARGETS, help="Target packages to install")
    parser.add_argument("--dry-run", action="store_true", help="Resolve dependencies without downloading")
    args = parser.parse_args()

    print(f">> Fetching package catalog from {args.mirror}...")
    all_pkgs = fetch_index(args.mirror)
    download_packages.all_pkgs = all_pkgs

    resolved = resolve_all_dependencies(args.targets, args.mirror, all_pkgs)
    download_packages(resolved, args.mirror, args.dest, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
