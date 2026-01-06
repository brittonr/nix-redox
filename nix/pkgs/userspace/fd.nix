# fd - Fast find alternative for Redox OS
#
# fd is a simple, fast and user-friendly alternative to 'find'.
# It's written in Rust and designed to be more intuitive than find.
#
# Source: github.com/sharkdp/fd (upstream, has Redox support via libc)
# Binary: fd
#
# Note: Requires patching faccess crate to use fallback implementation
# for Redox since faccessat() is not available in Redox libc.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  fd-src,
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      ;
  };

  # Patches for Redox OS compatibility
  # 1. faccess: Use fallback implementation (faccessat not available)
  # 2. fd: Disable owner filtering (nix crate's User/Group not available on Redox)
  redoxPatches = ''
        # Patch faccess to exclude Redox from unix implementation
        FACCESS_LIB="vendor-combined/faccess-0.2.4/src/lib.rs"
        if [ -f "$FACCESS_LIB" ]; then
          # Replace #[cfg(unix)] with #[cfg(all(unix, not(target_os = "redox")))]
          # to exclude Redox from the unix-specific implementation
          sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' "$FACCESS_LIB"

          # Also update the fallback condition to include Redox
          # Change: #[cfg(not(any(unix, windows)))]
          # To:     #[cfg(any(target_os = "redox", not(any(unix, windows))))]
          sed -i 's/#\[cfg(not(any(unix, windows)))\]/#[cfg(any(target_os = "redox", not(any(unix, windows))))]/g' "$FACCESS_LIB"

          # Regenerate checksum for the patched crate using inline Python
          ${pkgs.python3}/bin/python3 -c '
    import json
    import hashlib
    from pathlib import Path

    crate_dir = Path("vendor-combined/faccess-0.2.4")
    checksum_file = crate_dir / ".cargo-checksum.json"
    if checksum_file.exists():
        with open(checksum_file) as f:
            existing = json.load(f)
        pkg_hash = existing.get("package")
        files = {}
        for file_path in sorted(crate_dir.rglob("*")):
            if file_path.is_file() and file_path.name != ".cargo-checksum.json":
                rel_path = str(file_path.relative_to(crate_dir))
                with open(file_path, "rb") as f:
                    sha = hashlib.sha256(f.read()).hexdigest()
                files[rel_path] = sha
        new_data = {"files": files}
        if pkg_hash:
            new_data["package"] = pkg_hash
        with open(checksum_file, "w") as f:
            json.dump(new_data, f)
    '
        fi

        # Patch fd itself to exclude Redox from owner filtering
        # The nix crate's User/Group structs are not available on Redox
        # because RedoxFS doesn't support passwd
        # Files using owner filtering:
        # - src/filter/mod.rs: mod owner declaration
        # - src/config.rs: owner_constraint field
        # - src/main.rs: owner parsing
        # - src/walk.rs: owner constraint checking
        # - src/cli.rs: --owner CLI argument
        for fdfile in src/filter/mod.rs src/config.rs src/main.rs src/walk.rs src/cli.rs; do
          if [ -f "$fdfile" ]; then
            # Change #[cfg(unix)] to #[cfg(all(unix, not(target_os = "redox")))]
            # This disables owner filtering on Redox
            sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' "$fdfile"
          fi
        done
  '';

in
mkUserspace.mkBinary {
  pname = "fd";
  version = "10.2.0";
  src = fd-src;
  binaryName = "fd";

  # Vendor hash for fd dependencies
  vendorHash = "sha256-0LzraGDujLMs60/Ytq2hcG/3RYbo8sJkurYVhRpa2D8=";

  # Build fd without jemalloc (not supported on Redox)
  # Use --no-default-features to disable jemalloc, then enable completions only
  cargoBuildFlags = "--bin fd --no-default-features --features completions";

  # Apply Redox compatibility patches after vendor directory is set up
  postConfigure = redoxPatches;

  meta = with lib; {
    description = "Fast and user-friendly alternative to find for Redox OS";
    homepage = "https://github.com/sharkdp/fd";
    license = with licenses; [
      asl20
      mit
    ];
    mainProgram = "fd";
  };
}
