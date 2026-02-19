# Mock Packages for RedoxOS Module System Tests
#
# These are lightweight stand-ins for real cross-compiled packages.
# They provide the minimal directory structure that the build module expects,
# allowing us to test module evaluation and artifact generation without
# building the entire RedoxOS toolchain.
#
# Design philosophy:
#   - Create realistic file trees (bin/, boot/, etc.)
#   - Keep builds fast (no actual compilation)
#   - Match the interface the build module expects

{ pkgs, lib }:

let
  # Helper: create a package with binaries
  mkMockPackageWithBins =
    { name, binaries }:
    pkgs.runCommand "mock-${name}" { } ''
      mkdir -p $out/bin
      ${lib.concatMapStringsSep "\n" (bin: ''
        echo '#!/bin/sh' > $out/bin/${bin}
        echo 'echo "Mock ${bin} (from ${name})"' >> $out/bin/${bin}
        chmod +x $out/bin/${bin}
      '') binaries}
    '';

  # Helper: create a package with boot files
  mkMockBootPackage =
    { name, files }:
    pkgs.runCommand "mock-${name}" { } (
      ''
        mkdir -p $out/boot
      ''
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (filename: content: ''
          echo '${content}' > $out/boot/${filename}
        '') files
      )
    );

in
rec {
  # === Core System Packages ===

  # Base package: essential system daemons and utilities
  base = mkMockPackageWithBins {
    name = "base";
    binaries = [
      # Core daemons (required by initfs)
      "init"
      "logd"
      "ramfs"
      "randd"
      "zerod"
      "nulld"
      "pcid"
      "pcid-spawner"
      "lived"
      "acpid"
      "hwd"
      "rtcd"
      "ptyd"
      "ipcd"
      # Storage drivers
      "ahcid"
      "nvmed"
      "ided"
      "virtio-blkd"
      # Network drivers
      "e1000d"
      "virtio-netd"
      "smolnetd"
      # Graphics drivers
      "vesad"
      "inputd"
      "fbbootlogd"
      "fbcond"
      "ps2d"
      "virtio-gpud"
      "bgad"
      # USB support
      "xhcid"
      "usbhubd"
      "usbhidd"
      # Audio drivers
      "ihdad"
      "ac97d"
      "sb16d"
    ];
  };

  # Kernel package
  kernel = mkMockBootPackage {
    name = "kernel";
    files = {
      kernel = "Mock RedoxOS kernel binary";
    };
  };

  # Bootloader package
  bootloader = pkgs.runCommand "mock-bootloader" { } ''
    mkdir -p $out/boot/EFI/BOOT
    echo "Mock UEFI bootloader" > $out/boot/EFI/BOOT/BOOTX64.EFI
  '';

  # Bootstrap loader
  bootstrap = mkMockPackageWithBins {
    name = "bootstrap";
    binaries = [ "bootstrap" ];
  };

  # === Filesystem Tools (Host Packages) ===

  # RedoxFS (host tool)
  # These need to actually work to create filesystem images
  redoxfs = pkgs.runCommand "mock-redoxfs" { } ''
    mkdir -p $out/bin

    # Create a working redoxfs-ar that creates a dummy filesystem
    cat > $out/bin/redoxfs-ar << 'EOF'
    #!/bin/sh
    # Mock redoxfs-ar: creates a RedoxFS image from a directory
    # Usage: redoxfs-ar [--uid UID] [--gid GID] <image-file> <source-dir>

    # Parse arguments (simplified - just get last two args)
    while [ $# -gt 2 ]; do
      shift
    done

    image="$1"
    source="$2"

    echo "Mock redoxfs-ar: creating $image from $source"
    echo "Mock RedoxFS image" > "$image"
    EOF
    chmod +x $out/bin/redoxfs-ar

    # Create a simple redoxfs tool
    cat > $out/bin/redoxfs << 'EOF'
    #!/bin/sh
    echo "Mock redoxfs: $@"
    EOF
    chmod +x $out/bin/redoxfs
  '';

  # RedoxFS (target version)
  redoxfsTarget = mkMockPackageWithBins {
    name = "redoxfs-target";
    binaries = [ "redoxfs" ];
  };

  # Initfs tools (host)
  # This needs to actually work to create an initfs.img file
  initfsTools = pkgs.runCommand "mock-initfs-tools" { } ''
    mkdir -p $out/bin
    # Create a working redox-initfs-ar that creates a dummy initfs
    cat > $out/bin/redox-initfs-ar << 'EOF'
    #!/bin/sh
    # Mock redox-initfs-ar: takes source dir, bootstrap, and output file
    # Usage: redox-initfs-ar <source-dir> <bootstrap> -o <output-file>

    # Parse arguments
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) output="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done

    # Create a dummy initfs image (just a tar for now)
    echo "Mock initfs-ar: creating $output"
    echo "Mock RedoxOS initfs" > "$output"
    EOF
    chmod +x $out/bin/redox-initfs-ar
  '';

  # === Shell and Core Utilities ===

  # Ion shell
  ion = mkMockPackageWithBins {
    name = "ion";
    binaries = [
      "ion"
      "sh"
    ];
  };

  # Uutils (coreutils replacement)
  uutils = mkMockPackageWithBins {
    name = "uutils";
    binaries = [
      "ls"
      "cat"
      "echo"
      "mkdir"
      "rm"
      "cp"
      "mv"
      "chmod"
      "chown"
      "grep"
      "find"
      "head"
      "tail"
      "wc"
      "sort"
      "uniq"
      "cut"
      "tr"
      "sed"
      "awk"
    ];
  };

  # === Network Utilities ===

  netutils = mkMockPackageWithBins {
    name = "netutils";
    binaries = [
      "ping"
      "ifconfig"
      "dhcpd"
      "nc"
      "wget"
      "curl"
    ];
  };

  # === User Utilities ===

  userutils = mkMockPackageWithBins {
    name = "userutils";
    binaries = [
      "login"
      "getty"
      "passwd"
      "su"
      "sudo"
    ];
  };

  # === Editors ===

  # Helix editor
  helix = mkMockPackageWithBins {
    name = "helix";
    binaries = [ "hx" ];
  };

  # Sodium editor
  sodium = mkMockPackageWithBins {
    name = "sodium";
    binaries = [ "sodium" ];
  };

  # === Development Tools ===

  # Binutils (objdump, nm, etc.)
  binutils = mkMockPackageWithBins {
    name = "binutils";
    binaries = [
      "ar"
      "as"
      "ld"
      "nm"
      "objcopy"
      "objdump"
      "ranlib"
      "strip"
    ];
  };

  # Extra utilities
  extrautils = mkMockPackageWithBins {
    name = "extrautils";
    binaries = [
      "less"
      "which"
      "file"
      "tree"
    ];
  };

  # === Modern CLI Tools ===

  ripgrep = mkMockPackageWithBins {
    name = "ripgrep";
    binaries = [ "rg" ];
  };

  fd = mkMockPackageWithBins {
    name = "fd";
    binaries = [ "fd" ];
  };

  bat = mkMockPackageWithBins {
    name = "bat";
    binaries = [ "bat" ];
  };

  hexyl = mkMockPackageWithBins {
    name = "hexyl";
    binaries = [ "hexyl" ];
  };

  zoxide = mkMockPackageWithBins {
    name = "zoxide";
    binaries = [ "zoxide" ];
  };

  dust = mkMockPackageWithBins {
    name = "dust";
    binaries = [ "dust" ];
  };

  # === Graphics Packages ===

  # Orbital desktop
  orbital = mkMockPackageWithBins {
    name = "orbital";
    binaries = [
      "orbital"
      "orblogin"
    ];
  };

  # Orbital data
  orbdata = pkgs.runCommand "mock-orbdata" { } ''
    mkdir -p $out/share/fonts
    echo "Mock font data" > $out/share/fonts/font.ttf
  '';

  # Orbital terminal
  orbterm = mkMockPackageWithBins {
    name = "orbterm";
    binaries = [ "orbterm" ];
  };

  # Orbital utilities
  orbutils = mkMockPackageWithBins {
    name = "orbutils";
    binaries = [
      "orblogin"
      "calc"
      "editor"
      "file_manager"
      "launcher"
    ];
  };

  # === Network Configuration ===

  netcfg-setup = mkMockPackageWithBins {
    name = "netcfg-setup";
    binaries = [ "netcfg-setup" ];
  };

  # === Library Components ===

  # Relibc (Redox C library)
  relibc = pkgs.runCommand "mock-relibc" { } ''
    mkdir -p $out/lib
    echo "Mock C library" > $out/lib/libc.a
  '';

  # === Convenience: Flat package set ===
  # All packages in a single attrset for easy consumption
  all = {
    inherit
      base
      kernel
      bootloader
      bootstrap
      redoxfs
      redoxfsTarget
      initfsTools
      ion
      uutils
      netutils
      netcfg-setup
      userutils
      helix
      sodium
      binutils
      extrautils
      ripgrep
      fd
      bat
      hexyl
      zoxide
      dust
      orbital
      orbdata
      orbterm
      orbutils
      relibc
      ;
  };
}
