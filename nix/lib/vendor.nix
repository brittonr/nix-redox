# Vendor management utilities for Redox cross-compilation
#
# This module provides functions for merging Cargo vendor directories
# with version-aware conflict resolution. It eliminates ~80 lines of
# duplicated vendor merge logic from each cross-compiled package.

{ pkgs, lib }:

rec {
  # Python script for regenerating checksums after vendor merging
  # This is necessary because copying and modifying vendor directories
  # invalidates the original checksums.
  checksumScript = ''
    import json
    import hashlib
    from pathlib import Path

    vendor = Path("vendor-combined")
    for crate_dir in vendor.iterdir():
        if not crate_dir.is_dir():
            continue
        checksum_file = crate_dir / ".cargo-checksum.json"
        pkg_hash = None
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
  '';

  # Shell script for merging project vendor with sysroot vendor
  # Handles version conflicts by keeping both versions with suffixes
  mergeVendorsScript =
    { projectVendorVar, sysrootVendor }:
    ''
      # Helper to extract version from Cargo.toml
      get_version() {
        grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
      }

      mkdir -p vendor-combined

      # Copy project vendor crates
      for crate in ''${${projectVendorVar}}/*/; do
        crate_name=$(basename "$crate")
        # Skip .cargo and Cargo.lock
        if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
          continue
        fi
        if [ -d "$crate" ]; then
          cp -rL "$crate" "vendor-combined/$crate_name"
        fi
      done
      chmod -R u+w vendor-combined/

      # Merge sysroot vendor with version conflict resolution
      for crate in ${sysrootVendor}/*/; do
        crate_name=$(basename "$crate")
        if [ ! -d "$crate" ]; then
          continue
        fi
        if [ -d "vendor-combined/$crate_name" ]; then
          base_version=$(get_version "vendor-combined/$crate_name")
          sysroot_version=$(get_version "$crate")
          if [ "$base_version" != "$sysroot_version" ]; then
            # Keep both versions - add sysroot version with version suffix
            versioned_name="$crate_name-$sysroot_version"
            if [ ! -d "vendor-combined/$versioned_name" ]; then
              cp -rL "$crate" "vendor-combined/$versioned_name"
            fi
          fi
        else
          cp -rL "$crate" "vendor-combined/$crate_name"
        fi
      done
      chmod -R u+w vendor-combined/

      # Regenerate checksums
      ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
      ${checksumScript}
      PYTHON_CHECKSUM
    '';

  # Create a merged vendor directory as a separate derivation
  # This allows the merged vendor to be cached independently
  #
  # Parameters:
  #   name: Name prefix for the derivation
  #   projectVendor: Vendored dependencies from the project (fetchCargoVendor or crane)
  #   sysrootVendor: Vendored dependencies from sysroot (for -Z build-std)
  #   useCrane: Set to true if projectVendor is from crane (has nested hash-link structure)
  mkMergedVendor =
    {
      name,
      projectVendor,
      sysrootVendor,
      useCrane ? false,
    }:
    pkgs.runCommand "${name}-merged-vendor"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        mkdir -p vendor-combined

        # Helper to extract version from Cargo.toml
        get_version() {
          grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
        }

        ${
          if useCrane then
            ''
              # Crane uses nested hash-link directories - flatten the structure
              for hash_link in ${projectVendor}/*; do
                hash_name=$(basename "$hash_link")
                if [ "$hash_name" = "config.toml" ]; then
                  continue
                fi
                if [ -L "$hash_link" ]; then
                  resolved=$(readlink -f "$hash_link")
                  for crate_symlink in "$resolved"/*; do
                    if [ -L "$crate_symlink" ]; then
                      crate_name=$(basename "$crate_symlink")
                      crate_target=$(readlink -f "$crate_symlink")
                      if [ -d "$crate_target" ] && [ ! -d "vendor-combined/$crate_name" ]; then
                        cp -rL "$crate_target" "vendor-combined/$crate_name"
                      fi
                    fi
                  done
                elif [ -d "$hash_link" ]; then
                  for crate in "$hash_link"/*; do
                    if [ -d "$crate" ]; then
                      crate_name=$(basename "$crate")
                      if [ ! -d "vendor-combined/$crate_name" ]; then
                        cp -rL "$crate" "vendor-combined/$crate_name"
                      fi
                    fi
                  done
                fi
              done
            ''
          else
            ''
              # Standard fetchCargoVendor output - copy crates directly
              for crate in ${projectVendor}/*/; do
                crate_name=$(basename "$crate")
                if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
                  continue
                fi
                if [ -d "$crate" ]; then
                  cp -rL "$crate" "vendor-combined/$crate_name"
                fi
              done
            ''
        }
        chmod -R u+w vendor-combined/

        # Merge sysroot vendor with version conflict resolution
        for crate in ${sysrootVendor}/*/; do
          crate_name=$(basename "$crate")
          if [ ! -d "$crate" ]; then
            continue
          fi
          if [ -d "vendor-combined/$crate_name" ]; then
            base_version=$(get_version "vendor-combined/$crate_name")
            sysroot_version=$(get_version "$crate")
            if [ "$base_version" != "$sysroot_version" ]; then
              versioned_name="$crate_name-$sysroot_version"
              if [ ! -d "vendor-combined/$versioned_name" ]; then
                cp -rL "$crate" "vendor-combined/$versioned_name"
              fi
            fi
          else
            cp -rL "$crate" "vendor-combined/$crate_name"
          fi
        done
        chmod -R u+w vendor-combined/

        # Regenerate checksums
        ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
        ${checksumScript}
        PYTHON_CHECKSUM

        mv vendor-combined $out
      '';

  # Generate Cargo config.toml for vendored builds
  mkCargoConfig =
    {
      vendorDir ? "vendor-combined",
      gitSources ? [ ],
    }:
    ''
      [source.crates-io]
      replace-with = "combined-vendor"

      [source.combined-vendor]
      directory = "${vendorDir}"

      ${lib.concatMapStringsSep "\n" (src: ''
        [source."${src.url}"]
        replace-with = "combined-vendor"
        git = "${src.git}"
        ${lib.optionalString (src ? branch) "branch = \"${src.branch}\""}
        ${lib.optionalString (src ? rev) "rev = \"${src.rev}\""}
      '') gitSources}

      [net]
      offline = true
    '';
}
