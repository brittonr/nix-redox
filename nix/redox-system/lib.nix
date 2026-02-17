# RedoxOS System Library - Shared Helpers
#
# This module provides Redox-specific helper functions for the module system.
# It handles Redox's unique file formats and configuration patterns.
#
# Redox uses different formats than traditional Unix systems:
#   - passwd: semicolon-delimited (not colon)
#   - group: semicolon-delimited (not colon)
#   - pcid: TOML-based driver configuration (not udev rules)
#   - init.rc: Simple command-based init (not systemd units)
#
# These helpers abstract the format details and provide a clean interface
# for modules to generate configuration files.
#
# Usage in modules:
#   { config, lib, redoxSystemLib, ... }:
#   {
#     # Generate passwd entry
#     passwdEntry = redoxSystemLib.mkPasswdEntry {
#       name = "root";
#       uid = 0;
#       gid = 0;
#       home = "/root";
#       shell = "/bin/ion";
#     };
#   }

{ lib, pkgs }:

rec {
  # Generate Redox-format /etc/passwd line
  #
  # Redox passwd format: username;password;uid;gid;realname;home;shell
  # (differs from Unix: uses semicolons, not colons)
  #
  # Example:
  #   mkPasswdEntry {
  #     name = "user";
  #     uid = 1000;
  #     gid = 1000;
  #     home = "/home/user";
  #     shell = "/bin/ion";
  #   }
  #   => "user;;1000;1000;user;/home/user;/bin/ion"
  mkPasswdEntry =
    {
      name,
      password ? "", # Empty = no password, "!" = locked
      uid,
      gid,
      realname ? name, # Defaults to username if not provided
      home,
      shell,
      ...
    }:
    "${name};${password};${toString uid};${toString gid};${realname};${home};${shell}";

  # Generate Redox-format /etc/group line
  #
  # Redox group format: groupname;password;gid;members
  # (differs from Unix: uses semicolons, not colons)
  #
  # Example:
  #   mkGroupEntry {
  #     name = "wheel";
  #     gid = 1;
  #     members = ["user"];
  #   }
  #   => "wheel;x;1;user"
  mkGroupEntry =
    {
      name,
      password ? "x", # Standard placeholder
      gid,
      members ? [ ], # List of usernames
      ...
    }:
    "${name};${password};${toString gid};${lib.concatStringsSep "," members}";

  # Generate a PCI driver entry for pcid TOML configuration
  #
  # Redox uses pcid (PCI daemon) instead of udev for driver binding.
  # Configuration is TOML-based with driver entries matching PCI IDs.
  #
  # Matching criteria (all optional, first match wins):
  #   - name: String name for the entry (documentation only)
  #   - class: PCI class code (e.g., 0x03 for display)
  #   - subclass: PCI subclass code
  #   - vendor: PCI vendor ID (e.g., 0x8086 for Intel)
  #   - device: PCI device ID
  #
  # Command: Driver binary to execute (must be in /bin or /sbin)
  #
  # Example:
  #   mkPcidDriverEntry {
  #     name = "Intel HD Audio";
  #     class = 0x04;
  #     subclass = 0x03;
  #     vendor = 0x8086;
  #     command = "ihdad";
  #   }
  #   => [[drivers]]
  #      name = "Intel HD Audio"
  #      class = 0x04
  #      subclass = 0x03
  #      vendor = 0x8086
  #      command = ["ihdad"]
  mkPcidDriverEntry =
    {
      name ? null,
      class ? null,
      subclass ? null,
      vendor ? null,
      device ? null,
      command,
      ...
    }:
    let
      # Format integer as hex string (0x1234)
      formatHex = v: if builtins.isInt v then "0x${lib.toHexString v}" else toString v;

      # Generate optional TOML line (key = value)
      # Skips if value is null
      optLine =
        key: val:
        lib.optionalString (val != null) ''
          ${key} = ${
            if builtins.isString val then
              ''"${val}"''
            else if builtins.isInt val then
              formatHex val
            else
              toString val
          }
        '';
    in
    ''
      [[drivers]]
      ${optLine "name" name}${optLine "class" class}${optLine "subclass" subclass}${optLine "vendor" vendor}${optLine "device" device}command = ["${command}"]
    '';

  # Generate init.rc command line
  #
  # Redox uses init.rc (simple shell-like init script) instead of systemd.
  # Commands are executed sequentially at boot.
  #
  # Command types:
  #   - notify: Start service and wait for readiness notification
  #   - nowait: Start service in background (don't wait)
  #   - run: Execute command and wait for completion
  #   - export: Set environment variable
  #   - raw: Raw line (for comments, etc.)
  #
  # Example:
  #   mkInitRcLine { type = "notify"; args = "ramfs /"; }
  #   => "notify ramfs /"
  #
  #   mkInitRcLine { type = "export"; args = "PATH=/bin:/usr/bin"; }
  #   => "export PATH=/bin:/usr/bin"
  #
  #   mkInitRcLine { type = "raw"; args = "# Start networking"; }
  #   => "# Start networking"
  mkInitRcLine = cmd: if cmd.type == "raw" then cmd.args else "${cmd.type} ${cmd.args}";

  # Generate multiple init.rc lines from a list
  mkInitRcLines = cmds: lib.concatMapStringsSep "\n" mkInitRcLine cmds;

  # Collect binaries from a package into a target directory
  #
  # Returns a bash shell fragment that copies binaries.
  # Useful for building initfs or rootfs.
  #
  # Example:
  #   installPackageBins { pkg = pkgs.ion; dest = "$out/bin"; }
  #   => Shell script that copies ion/bin/* to $out/bin/
  installPackageBins =
    { pkg, dest }:
    ''
      if [ -d "${pkg}/bin" ]; then
        for f in ${pkg}/bin/*; do
          [ -e "$f" ] || continue
          cp "$f" ${dest}/$(basename "$f") 2>/dev/null || true
        done
      fi
    '';

  # Collect binaries with symlinking (for /usr/bin)
  #
  # Similar to installPackageBins but creates symlinks instead of copies.
  # More efficient for disk space but requires original paths to exist.
  #
  # Example:
  #   linkPackageBins { pkg = pkgs.helix; dest = "$out/usr/bin"; }
  linkPackageBins =
    { pkg, dest }:
    ''
      if [ -d "${pkg}/bin" ]; then
        for f in ${pkg}/bin/*; do
          [ -e "$f" ] || continue
          ln -sf "$f" ${dest}/$(basename "$f") 2>/dev/null || true
        done
      fi
    '';

  # Install entire directory tree from package
  #
  # Recursively copies a directory from a package to a destination.
  # Useful for installing /etc, /usr/share, etc.
  #
  # Example:
  #   installPackageDir { pkg = pkgs.orbdata; src = "/share/fonts"; dest = "$out/usr/share/fonts"; }
  installPackageDir =
    {
      pkg,
      src,
      dest,
    }:
    ''
      if [ -d "${pkg}${src}" ]; then
        mkdir -p ${dest}
        cp -r ${pkg}${src}/* ${dest}/ 2>/dev/null || true
      fi
    '';

  # Generate a simple file from string content
  #
  # Creates a derivation that contains a single file.
  # Useful for configuration files, scripts, etc.
  #
  # Example:
  #   mkFile { name = "init.rc"; content = "notify ramfs /\n"; }
  mkFile =
    { name, content }:
    pkgs.writeTextFile {
      inherit name;
      text = content;
    };

  # Generate a directory with files
  #
  # Creates a derivation with a directory structure.
  # Input is an attrset where keys are paths and values are contents.
  #
  # Example:
  #   mkFileTree {
  #     name = "etc";
  #     files = {
  #       "passwd" = "root;;0;0;root;/root;/bin/ion\n";
  #       "group" = "root;x;0;\n";
  #       "network/ip" = "172.16.0.2\n";
  #     };
  #   }
  mkFileTree =
    { name, files }:
    pkgs.runCommand name { } (
      ''
        mkdir -p $out
      ''
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          path: content:
          let
            dir = builtins.dirOf path;
          in
          ''
            ${lib.optionalString (dir != ".") "mkdir -p $out/${dir}"}
            cat > $out/${path} << 'EOF'
            ${content}
            EOF
          ''
        ) files
      )
    );

  # Merge multiple file trees
  #
  # Combines multiple derivations into a single directory.
  # Later entries override earlier ones on conflict.
  #
  # Example:
  #   mergeFileTrees {
  #     name = "rootfs";
  #     trees = [ baseFiles extraFiles ];
  #   }
  mergeFileTrees =
    { name, trees }:
    pkgs.runCommand name { } ''
      mkdir -p $out
      ${lib.concatMapStringsSep "\n" (tree: ''
        if [ -d "${tree}" ]; then
          cp -rf ${tree}/* $out/ 2>/dev/null || true
        fi
      '') trees}
    '';
}
