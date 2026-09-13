#!/usr/bin/env python3
"""
fetch_packages.py - Automated OpenBSD Package Dependency Resolver & Downloader.

Recursively resolves and downloads OpenBSD arm packages for offline installation
on Pomera DM250 into _build_cache/packages. Includes robust manifest caching,
local package dependency extraction, and IPv4 prioritization to eliminate
redundant remote catalog downloads and graph resolutions.

Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
SPDX-License-Identifier: MIT
"""

import os
import sys
import re
import io
import json
import zlib
import socket
import urllib.request
import argparse
from typing import Dict, List, Set, Optional

# Prioritize IPv4 to prevent hanging on IPv6 SYN_SENT timeouts in dual-stack hosts
_orig_getaddrinfo = socket.getaddrinfo
def _getaddrinfo_prefer_ipv4(host, port, family=0, type=0, proto=0, flags=0):
    try:
        res = _orig_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)
        if res:
            return res
    except Exception:
        pass
    return _orig_getaddrinfo(host, port, family, type, proto, flags)
socket.getaddrinfo = _getaddrinfo_prefer_ipv4

MIRROR_URL = "https://cdn.openbsd.org/pub/OpenBSD/7.9/packages/arm/"
DEFAULT_TARGETS = ["vim", "curl", "git", "noto-cjk", "dmenu", "fribidi", "harfbuzz"]
MANIFEST_NAME = ".packages_manifest.json"


def check_cached_manifest(dest_dir: str, mirror: str, targets: List[str]) -> Optional[Dict[str, int]]:
    """
    Checks if a valid packages manifest exists and all package files match expected sizes.
    Returns dictionary of {pkg_filename: size} if valid, or None if invalid/incomplete.
    """
    manifest_path = os.path.join(dest_dir, MANIFEST_NAME)
    if not os.path.isfile(manifest_path):
        return None

    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        if data.get("mirror") != mirror:
            return None

        if sorted(data.get("targets", [])) != sorted(targets):
            return None

        pkgs = data.get("packages", {})
        if not pkgs:
            return None

        for pkg_name, expected_size in pkgs.items():
            fpath = os.path.join(dest_dir, pkg_name)
            if not os.path.isfile(fpath):
                return None
            if expected_size > 0 and os.path.getsize(fpath) != expected_size:
                return None

        return pkgs
    except Exception:
        return None


def save_manifest(dest_dir: str, mirror: str, targets: List[str], pkgs: Set[str], all_pkgs: Dict[str, int]):
    """
    Saves resolved packages manifest into dest_dir for sub-second cache verification.
    """
    os.makedirs(dest_dir, exist_ok=True)
    manifest_path = os.path.join(dest_dir, MANIFEST_NAME)
    manifest_data = {
        "mirror": mirror,
        "targets": sorted(targets),
        "packages": {
            p: all_pkgs.get(p, os.path.getsize(os.path.join(dest_dir, p)) if os.path.isfile(os.path.join(dest_dir, p)) else 0)
            for p in sorted(pkgs)
        }
    }
    temp_path = manifest_path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as f:
        json.dump(manifest_data, f, indent=2)
    os.rename(temp_path, manifest_path)
    print(f"✅ Package cache manifest saved ({len(pkgs)} packages tracked).")


def fetch_index(mirror: str, cache_dir: Optional[str] = None) -> Dict[str, int]:
    index_cache = os.path.join(cache_dir, ".index.txt") if cache_dir else None

    # Fetch index.txt
    url = mirror + "index.txt"
    req = urllib.request.Request(url, headers={"User-Agent": "OpenBSD-Pomera-Installer"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = resp.read().decode("utf-8", errors="ignore")
            if index_cache:
                try:
                    with open(index_cache, "w", encoding="utf-8") as f:
                        f.write(data)
                except Exception:
                    pass
    except Exception as e:
        if index_cache and os.path.isfile(index_cache):
            print(f"⚠️ Network notice: using local cached index.txt ({e})", file=sys.stderr)
            with open(index_cache, "r", encoding="utf-8") as f:
                data = f.read()
        else:
            raise

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


def parse_contents_from_chunk(chunk: bytes) -> List[str]:
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


def extract_package_dependencies(mirror: str, pkg_filename: str, dest_dir: Optional[str] = None) -> List[str]:
    # 1. High-speed local extraction: If package is already cached locally, inspect it directly
    if dest_dir:
        local_path = os.path.join(dest_dir, pkg_filename)
        if os.path.isfile(local_path):
            try:
                with open(local_path, "rb") as f:
                    chunk = f.read(524288) # Read initial 512KB containing +CONTENTS
                deps = parse_contents_from_chunk(chunk)
                if deps or os.path.getsize(local_path) > 0:
                    return deps
            except Exception as e:
                print(f"⚠️ Warning: Could not read local {pkg_filename}: {e}", file=sys.stderr)

    # 2. Remote range-read from mirror
    url = mirror + pkg_filename
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "OpenBSD-Pomera-Installer", "Range": "bytes=0-262143"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            chunk = resp.read()
        return parse_contents_from_chunk(chunk)
    except Exception as e:
        print(f"⚠️ Warning: Could not range-read {pkg_filename}: {e}", file=sys.stderr)
        return []


def resolve_all_dependencies(targets: List[str], mirror: str, all_pkgs: Dict[str, int], dest_dir: Optional[str] = None) -> Set[str]:
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

        deps = extract_package_dependencies(mirror, current, dest_dir=dest_dir)
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
        with urllib.request.urlopen(req, timeout=15) as resp, open(temp_dest, "wb") as out:
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
    parser.add_argument("--no-cache", "--force", action="store_true", dest="force", help="Force refresh and ignore cached manifest")
    args = parser.parse_args()

    # Fast cache check: if all requested targets are already resolved & present, skip network entirely
    if not args.force:
        cached_manifest = check_cached_manifest(args.dest, args.mirror, args.targets)
        if cached_manifest is not None:
            total_sz = sum(cached_manifest.values())
            print(f"✅ [Packages Cache] All {len(cached_manifest)} offline workspace packages are already cached ({total_sz / 1024 / 1024:.1f} MB).")
            print(f"   -> Destination: {args.dest}")
            print("   -> Skipping remote catalog fetch and dependency resolution (Use --no-cache to re-fetch).")
            return

    print(f">> Fetching package catalog from {args.mirror}...")
    all_pkgs = fetch_index(args.mirror, cache_dir=args.dest)
    download_packages.all_pkgs = all_pkgs

    resolved = resolve_all_dependencies(args.targets, args.mirror, all_pkgs, dest_dir=args.dest)
    download_packages(resolved, args.mirror, args.dest, dry_run=args.dry_run)

    if not args.dry_run:
        save_manifest(args.dest, args.mirror, args.targets, resolved, all_pkgs)


if __name__ == "__main__":
    main()
