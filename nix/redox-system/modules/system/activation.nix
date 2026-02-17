# RedoxOS Root Filesystem Activation
#
# This module CONSUMES configuration and produces the root filesystem tree.
# It implements the "disko pattern" - pure Nix config → derivation.
#
# Inputs (from config):
#   - config.redox.generatedFiles: All generated config files
#   - config.redox.environment.systemPackages: Packages to install
#   - config.redox.filesystem.extraDirectories: Directories to create
#   - config.redox.filesystem.devSymlinks: /dev/* symlinks
#   - config.redox.filesystem.specialSymlinks: Other symlinks (sh -> ion)
#   - config.redox.users.users: User accounts (for home directory creation)
#
# Output:
#   - system.build.rootTree: Derivation containing the assembled root filesystem

{
  config,
  lib,
  pkgs,
  hostPkgs,
  redoxSystemLib,
  ...
}:

let
  inherit (lib)
    mkOption
    mkIf
    types
    concatStringsSep
    mapAttrsToList
    optionalString
    filter
    ;

  cfg = config.redox;

  # Generate shell commands to create directories
  mkDirs =
    dirs: concatStringsSep "\n" (map (dir: "mkdir -p $out${dir}") (filter (d: d != null) dirs));

  # Generate shell commands to create symlinks
  mkSymlinks =
    symlinks:
    concatStringsSep "\n" (
      mapAttrsToList (
        name: target:
        let
          dir = builtins.dirOf name;
        in
        ''
          ${optionalString (dir != "." && dir != "/") "mkdir -p $out/${dir}"}
          ln -sf ${target} $out/${name}
        ''
      ) symlinks
    );

  # Generate shell commands to write generated files
  # Uses writeTextFile to avoid heredoc escaping issues
  mkGeneratedFiles =
    files:
    concatStringsSep "\n" (
      mapAttrsToList (
        path: file:
        let
          dir = builtins.dirOf path;
          # Create a store file with the content, then copy it
          storeFile = hostPkgs.writeText (builtins.replaceStrings [ "/" ] [ "-" ] path) file.text;
        in
        ''
          ${optionalString (dir != "." && dir != "/") "mkdir -p $out/${dir}"}
          cp ${storeFile} $out/${path}
          chmod ${file.mode} $out/${path}
        ''
      ) files
    );

  # Generate shell commands to install system packages
  # Copies all binaries from each package to both /bin and /usr/bin
  mkSystemPackages =
    packages:
    concatStringsSep "\n" (
      map (pkg: ''
        if [ -d "${pkg}/bin" ]; then
          echo "Installing package: ${pkg.name or "unknown"}"
          for f in ${pkg}/bin/*; do
            [ -e "$f" ] || continue
            cp "$f" $out/bin/$(basename "$f") 2>/dev/null || true
            cp "$f" $out/usr/bin/$(basename "$f") 2>/dev/null || true
          done
        fi
      '') packages
    );

  # Collect home directories to create
  homeDirs = mapAttrsToList (name: user: if user.createHome then user.home else null) cfg.users.users;

in
{
  config.system.build.rootTree =
    hostPkgs.runCommand "redox-root-tree"
      {
        # Pass packages as build inputs so Nix tracks dependencies
        buildInputs = cfg.environment.systemPackages;
      }
      ''
        # Create base directory structure
        echo "Creating base directory structure..."
        ${mkDirs cfg.filesystem.extraDirectories}

        # Create home directories for users
        echo "Creating user home directories..."
        ${mkDirs homeDirs}

        # Create /dev symlinks (Redox scheme compatibility)
        echo "Creating /dev symlinks..."
        mkdir -p $out/dev
        ${mkSymlinks (
          lib.mapAttrs' (name: target: {
            name = "dev/${name}";
            value = target;
          }) cfg.filesystem.devSymlinks
        )}

        # Create special symlinks (sh -> ion, etc.)
        echo "Creating special symlinks..."
        ${mkSymlinks cfg.filesystem.specialSymlinks}

        # Install system packages
        echo "Installing system packages..."
        ${mkSystemPackages cfg.environment.systemPackages}

        # Write all generated files
        echo "Writing generated configuration files..."
        ${mkGeneratedFiles cfg.generatedFiles}

        # Verify critical files
        echo ""
        echo "=== Root tree assembly complete ==="
        echo "Verifying critical files:"
        ls -l $out/bin/ion 2>/dev/null || echo "WARNING: /bin/ion missing!"
        ls -l $out/bin/sh 2>/dev/null || echo "WARNING: /bin/sh missing!"
        ls -l $out/etc/passwd 2>/dev/null || echo "WARNING: /etc/passwd missing!"
        echo ""
        echo "Directory structure:"
        find $out -maxdepth 2 -type d | sort
        echo ""
        echo "Binary count: $(find $out/bin -type f 2>/dev/null | wc -l)"
        echo "Config file count: $(find $out/etc -type f 2>/dev/null | wc -l)"
      '';
}
