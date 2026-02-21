# push-to-redox: Push cross-compiled packages to a running Redox VM
#
# Builds packages on the host, serializes to Nix binary cache format,
# and writes to the shared directory where virtio-fs makes them available
# to the guest at /scheme/shared/cache/.
#
# The guest uses: snix install <name> --cache-path /scheme/shared/cache
#
# Usage:
#   push-to-redox ripgrep             # Push one package
#   push-to-redox ripgrep fd bat      # Push multiple
#   push-to-redox --all               # Push all available cross-compiled packages
#   push-to-redox --list              # List available packages

{
  pkgs,
  lib,
  self,
}:

let
  python = pkgs.python3;
  zstd = pkgs.zstd;
  nix = pkgs.nix;

  # The NAR serializer / cache builder from the build system
  buildBinaryCachePy = ../../lib/build-binary-cache.py;

  pushScript = pkgs.writeText "push-to-redox.py" ''
    #!/usr/bin/env python3
    """Push cross-compiled packages to a Redox VM via shared filesystem."""

    import argparse
    import json
    import os
    import shutil
    import subprocess
    import sys
    import tempfile

    # Known packages: name → flake attribute
    KNOWN_PACKAGES = {
        "ripgrep": "ripgrep",
        "fd": "fd",
        "bat": "bat",
        "hexyl": "hexyl",
        "zoxide": "zoxide",
        "dust": "dust",
        "ion": "ion-shell",
        "uutils": "uutils",
        "snix": "snix",
        "userutils": "userutils",
        "orbital": "orbital",
        "orbterm": "orbterm",
        "orbutils": "orbutils",
        "orbdata": "orbdata",
        "sodium": "sodium",
    }

    # ANSI colors (only if terminal)
    if sys.stderr.isatty():
        RED = "\033[1;31m"
        GREEN = "\033[1;32m"
        BLUE = "\033[1;34m"
        YELLOW = "\033[1;33m"
        BOLD = "\033[1m"
        RESET = "\033[0m"
    else:
        RED = GREEN = BLUE = YELLOW = BOLD = RESET = ""


    def eprint(*args, **kwargs):
        print(*args, file=sys.stderr, **kwargs)


    # Tool paths (set by wrapper script)
    NIX = os.environ.get("NIX", "nix")
    PYTHON = os.environ.get("PYTHON", "python3")
    BUILD_CACHE_PY = os.environ.get("BUILD_CACHE_PY", "build-binary-cache.py")


    def build_package(flake_dir, attr):
        """Build a package and return its store path."""
        result = subprocess.run(
            [NIX, "build", f"{flake_dir}#{attr}", "--no-link", "--print-out-paths"],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            return None
        return result.stdout.strip().split("\n")[-1]


    def parse_store_path(store_path):
        """Extract version from store path name.
        /nix/store/{hash}-{pname}-{version} → version
        """
        basename = os.path.basename(store_path)
        name_part = basename[33:]  # skip hash + dash

        # Split on last dash: "ripgrep-14.1.0" → ("ripgrep", "14.1.0")
        # Also handles: "ripgrep-unstable" → ("ripgrep", "unstable")
        parts = name_part.rsplit("-", 1)
        if len(parts) == 2 and parts[1]:
            return parts[1]
        return name_part


    def merge_cache(src_dir, dst_dir):
        """Merge a generated binary cache into the target shared cache."""
        os.makedirs(os.path.join(dst_dir, "nar"), exist_ok=True)

        # Copy narinfo files
        for f in os.listdir(src_dir):
            if f.endswith(".narinfo"):
                shutil.copy2(os.path.join(src_dir, f), os.path.join(dst_dir, f))

        # Copy NAR files
        src_nar = os.path.join(src_dir, "nar")
        dst_nar = os.path.join(dst_dir, "nar")
        if os.path.isdir(src_nar):
            for f in os.listdir(src_nar):
                shutil.copy2(os.path.join(src_nar, f), os.path.join(dst_nar, f))

        # Merge packages.json
        src_index = {}
        src_idx_path = os.path.join(src_dir, "packages.json")
        if os.path.exists(src_idx_path):
            with open(src_idx_path) as f:
                src_index = json.load(f)

        dst_index = {"version": 1, "packages": {}}
        dst_idx_path = os.path.join(dst_dir, "packages.json")
        if os.path.exists(dst_idx_path):
            with open(dst_idx_path) as f:
                dst_index = json.load(f)

        new_pkgs = src_index.get("packages", {})
        dst_index["packages"].update(new_pkgs)

        with open(dst_idx_path, "w") as f:
            json.dump(dst_index, f, indent=2, sort_keys=True)

        # Ensure nix-cache-info exists
        cache_info = os.path.join(dst_dir, "nix-cache-info")
        if not os.path.exists(cache_info):
            with open(cache_info, "w") as f:
                f.write("StoreDir: /nix/store\n")

        return len(new_pkgs)


    def list_packages(cache_dir):
        """List available and cached packages."""
        eprint(f"{BOLD}Available packages:{RESET}")
        eprint()
        for name in sorted(KNOWN_PACKAGES):
            attr = KNOWN_PACKAGES[name]
            eprint(f"  {name:<16} .#{attr}")

        eprint()
        eprint(f"{BOLD}Currently in shared cache ({cache_dir}):{RESET}")
        idx_path = os.path.join(cache_dir, "packages.json")
        if os.path.exists(idx_path):
            with open(idx_path) as f:
                idx = json.load(f)
            pkgs = idx.get("packages", {})
            if not pkgs:
                eprint("  (empty)")
            else:
                for name, entry in sorted(pkgs.items()):
                    ver = entry.get("version", "?")
                    size = entry.get("fileSize")
                    size_str = format_size(size) if size else "?"
                    eprint(f"  {name:<16} {ver:<12} {size_str:>8}")
        else:
            eprint("  (no cache yet)")


    def format_size(n):
        if n >= 1024 * 1024:
            return f"{n / (1024*1024):.1f} MB"
        elif n >= 1024:
            return f"{n // 1024} KB"
        return f"{n} B"


    def main():
        parser = argparse.ArgumentParser(
            prog="push-to-redox",
            description="Push cross-compiled packages to a running Redox VM"
        )
        parser.add_argument("packages", nargs="*", help="Package names to push")
        parser.add_argument("--all", action="store_true", help="Push all available packages")
        parser.add_argument("--list", action="store_true", help="List available packages")
        parser.add_argument("--shared-dir", default=None, help="Shared directory (default: $REDOX_SHARED_DIR or /tmp/redox-shared)")
        parser.add_argument("--flake-dir", default=None, help="Flake directory (default: $REDOX_FLAKE_DIR or .)")
        args = parser.parse_args()

        shared_dir = args.shared_dir or os.environ.get("REDOX_SHARED_DIR", "/tmp/redox-shared")
        cache_dir = os.path.join(shared_dir, "cache")
        flake_dir = args.flake_dir or os.environ.get("REDOX_FLAKE_DIR", os.getcwd())

        if args.list:
            list_packages(cache_dir)
            return

        packages = args.packages
        if args.all:
            packages = sorted(KNOWN_PACKAGES.keys())

        if not packages:
            parser.print_help()
            sys.exit(1)

        os.makedirs(cache_dir, exist_ok=True)

        eprint(f"{BOLD}push-to-redox{RESET}")
        eprint(f"  Shared: {shared_dir}")
        eprint(f"  Cache:  {cache_dir}")
        eprint(f"  Flake:  {flake_dir}")
        eprint()

        # Phase 1: Build packages
        built = []   # (name, store_path, pname, version)
        failed = []

        for name in packages:
            attr = KNOWN_PACKAGES.get(name)
            if not attr:
                eprint(f"{YELLOW}⚠ Unknown package: {name} (skipping){RESET}")
                eprint(f"  Run --list to see available packages")
                failed.append(name)
                continue

            eprint(f"{BLUE}Building {name} (.#{attr})...{RESET} ", end="", flush=True)

            store_path = build_package(flake_dir, attr)
            if store_path is None:
                eprint(f"{RED}FAILED{RESET}")
                failed.append(name)
                continue

            version = parse_store_path(store_path)
            eprint(f"{GREEN}✓{RESET} {store_path}")
            built.append((name, store_path, attr, version))

        if not built:
            eprint()
            eprint(f"{RED}No packages built successfully.{RESET}")
            sys.exit(1)

        eprint()

        # Phase 2: Generate binary cache in temp dir
        tmpdir = tempfile.mkdtemp(prefix="push-redox-")
        try:
            # Write package info JSON
            entries = []
            for name, store_path, pname, version in built:
                entries.append({
                    "name": name,
                    "storePath": store_path,
                    "pname": pname,
                    "version": version,
                })

            info_path = os.path.join(tmpdir, "package-info.json")
            with open(info_path, "w") as f:
                json.dump(entries, f, indent=2)

            cache_tmp = os.path.join(tmpdir, "cache")
            eprint(f"{BLUE}Serializing to binary cache format...{RESET}")
            result = subprocess.run(
                [PYTHON, BUILD_CACHE_PY, info_path, cache_tmp],
                capture_output=False
            )
            if result.returncode != 0:
                eprint(f"{RED}Cache generation failed{RESET}")
                sys.exit(1)

            # Phase 3: Merge into shared cache
            eprint()
            eprint(f"{BLUE}Merging into shared cache...{RESET}")
            n = merge_cache(cache_tmp, cache_dir)
            eprint(f"  Merged {n} packages into {cache_dir}")

        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

        # Summary
        eprint()
        eprint(f"{GREEN}{BOLD}Done!{RESET} Pushed {len(built)} package(s) to {cache_dir}")
        if failed:
            eprint(f"{YELLOW}Failed: {', '.join(failed)}{RESET}")
        eprint()
        eprint(f"{BOLD}On the guest (Redox):{RESET}")
        eprint(f"  snix search --cache-path /scheme/shared/cache")
        for name, _, _, _ in sorted(built):
            eprint(f"  snix install {name} --cache-path /scheme/shared/cache")


    if __name__ == "__main__":
        main()
  '';
in
pkgs.writeShellScriptBin "push-to-redox" ''
  export PATH="${
    lib.makeBinPath [
      python
      zstd
      nix
    ]
  }:$PATH"

  # Make the Python script aware of tool paths
  export NIX="${nix}/bin/nix"
  export PYTHON="${python}/bin/python3"
  export BUILD_CACHE_PY="${buildBinaryCachePy}"

  exec ${python}/bin/python3 ${pushScript} "$@"
''
