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
    {
      name,
      binaries,
      pname ? null,
      extraSetup ? "",
    }:
    (pkgs.runCommand "mock-${name}" { } ''
      mkdir -p $out/bin
      ${lib.concatMapStringsSep "\n" (bin: ''
        echo '#!/bin/sh' > $out/bin/${bin}
        echo 'echo "Mock ${bin} (from ${name})"' >> $out/bin/${bin}
        chmod +x $out/bin/${bin}
      '') binaries}
      ${extraSetup}
    '')
    // (lib.optionalAttrs (pname != null) { inherit pname; });

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
    pname = "redox-base";
    # xhcid reads its USB class driver table from /usr/lib/xhcid.d at runtime;
    # the real base package stages drivers.toml there and initfs copies it.
    extraSetup = ''
      mkdir -p $out/usr/lib/xhcid.d
      echo '# mock USB class driver table' > $out/usr/lib/xhcid.d/drivers.toml
    '';
    binaries = [
      # Core daemons (required by initfs)
      "init"
      "getty"
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
      "udsd"
      # Storage drivers
      "ahcid"
      "nvmed"
      "ided"
      "virtio-blkd"
      # Network drivers
      "e1000d"
      "igcd"
      "virtio-netd"
      "smolnetd"
      # Graphics drivers
      "vesad"
      "inputd"
      "fbbootlogd"
      "fbcond"
      "ps2d"
      "virtio-gpud"
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
    pname = "ion-shell";
    binaries = [
      "ion"
      "sh"
    ];
  };

  # Uutils (coreutils replacement)
  uutils = mkMockPackageWithBins {
    name = "uutils";
    pname = "redox-uutils";
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
    pname = "userutils";
    binaries = [
      "login"
      "passwd"
      "su"
      "sudo"
      "id"
      "whoami"
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

  # === Package Management ===

  # Snix package manager
  snix = mkMockPackageWithBins {
    name = "snix";
    pname = "snix-redox";
    binaries = [ "snix" ];
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

  # Orbital data (fonts, icons, cursors, config)
  # Upstream assets live under usr/share/{ui,fonts,icons,applications}.
  orbdata =
    (pkgs.runCommand "mock-orbdata" { } ''
      mkdir -p $out/usr/share/ui $out/usr/share/fonts/Mono/Fira \
        $out/usr/share/fonts/Sans/Fira $out/usr/share/icons/apps $out/usr/share/applications
      cat > $out/usr/share/ui/orbital.toml << 'EOF'
      cursor = "/usr/share/ui/left_ptr.png"
      bottom_left_corner = "/usr/share/ui/bottom_left_corner.png"
      bottom_right_corner = "/usr/share/ui/bottom_right_corner.png"
      bottom_side = "/usr/share/ui/bottom_side.png"
      left_side = "/usr/share/ui/left_side.png"
      right_side = "/usr/share/ui/right_side.png"
      window_max = "/usr/share/ui/window_max.png"
      window_max_unfocused = "/usr/share/ui/window_max_unfocused.png"
      window_close = "/usr/share/ui/window_close.png"
      window_close_unfocused = "/usr/share/ui/window_close_unfocused.png"
      EOF
      echo "mock cursor" > $out/usr/share/ui/left_ptr.png
      echo "mock background" > $out/usr/share/ui/background.jpg
      echo "mock font" > $out/usr/share/fonts/Mono/Fira/Regular.ttf
      echo "mock font" > $out/usr/share/fonts/Sans/Fira/Regular.ttf
      echo "mock icon" > $out/usr/share/icons/apps/utilities-terminal.png
      echo "mock mimeapps" > $out/usr/share/applications/mimeapps.list
    '')
    // {
      pname = "orbdata";
    };

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

  # === SSH ===

  openssh = mkMockPackageWithBins {
    name = "openssh";
    pname = "openssh";
    binaries = [
      "ssh"
      "sshd"
      "ssh-keygen"
      "scp"
      "sftp"
      "sftp-server"
    ];
  };

  # === Scheme Daemons ===

  exampled = mkMockPackageWithBins {
    name = "exampled";
    pname = "exampled";
    binaries = [ "exampled" ];
  };

  # === Network Configuration ===

  netcfg-setup = mkMockPackageWithBins {
    name = "netcfg-setup";
    pname = "netcfg-setup";
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
      snix
      orbital
      orbdata
      orbterm
      orbutils
      relibc
      openssh
      exampled
      ;
  };
}
