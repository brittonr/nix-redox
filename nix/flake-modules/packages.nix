# RedoxOS packages module (adios-flake)
#
# Exports all RedoxOS packages through the standard flake interface.
# Uses redox-env.nix for shared toolchain/config computation.
#
# Access via:
#   self.packages.${system}.cookbook
#   self.packages.${system}.relibc

{
  pkgs,
  system,
  lib,
  self,
  ...
}:
let
  inputs = self.inputs;

  # Shared build environment (config + toolchain + sources + modular packages)
  env = import ./redox-env.nix {
    inherit
      pkgs
      system
      lib
      inputs
      ;
  };

  inherit (env)
    rustToolchain
    craneLib
    sysrootVendor
    redoxTarget
    redoxLib
    modularPkgs
    ;

  # Common args for all standalone packages
  standaloneCommon = {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      ;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs vendor;
  };

  # === Standalone packages (special handling, not in modularPkgs) ===

  sodium = import ../pkgs/userspace/sodium.nix (
    standaloneCommon
    // {
      inherit (inputs) sodium-src orbclient-src;
    }
  );

  orbdata = import ../pkgs/userspace/orbdata.nix {
    inherit pkgs lib;
    inherit (inputs) orbdata-src;
  };

  orbital = import ../pkgs/userspace/orbital.nix (
    standaloneCommon
    // {
      inherit craneLib;
      inherit (inputs)
        orbital-src
        orbclient-src
        orbfont-src
        orbimage-src
        libredox-src
        relibc-src
        liblibc-src
        rustix-redox-src
        drm-rs-src
        redox-log-src
        redox-syscall-src
        redox-scheme-src
        base-orbital-compat-src
        ;
    }
  );

  orbterm = import ../pkgs/userspace/orbterm.nix (
    standaloneCommon
    // {
      inherit (inputs)
        orbterm-src
        orbclient-src
        orbfont-src
        orbimage-src
        libredox-src
        relibc-src
        ;
    }
  );

  orbutils = import ../pkgs/userspace/orbutils.nix (
    standaloneCommon
    // {
      inherit (inputs) orbutils-src;
    }
  );

  userutils = import ../pkgs/userspace/userutils.nix (
    standaloneCommon
    // {
      inherit craneLib;
      inherit (inputs)
        userutils-src
        termion-src
        orbclient-src
        libredox-src
        ;
    }
  );

  ripgrep = import ../pkgs/userspace/ripgrep.nix (
    standaloneCommon
    // {
      inherit (inputs) ripgrep-src;
    }
  );

  fd = import ../pkgs/userspace/fd.nix (
    standaloneCommon
    // {
      inherit (inputs) fd-src;
    }
  );

  bat = import ../pkgs/userspace/bat.nix (
    standaloneCommon
    // {
      inherit (inputs) bat-src;
    }
  );

  hexyl = import ../pkgs/userspace/hexyl.nix (
    standaloneCommon
    // {
      inherit (inputs) hexyl-src;
    }
  );

  zoxide = import ../pkgs/userspace/zoxide.nix (
    standaloneCommon
    // {
      inherit (inputs) zoxide-src;
    }
  );

  dust = import ../pkgs/userspace/dust.nix (
    standaloneCommon
    // {
      inherit (inputs) dust-src;
    }
  );

  snix = import ../pkgs/userspace/snix.nix (
    standaloneCommon
    // {
      snix-redox-src = ../../snix-redox;
    }
  );

  tokei = import ../pkgs/userspace/tokei.nix (
    standaloneCommon
    // {
      inherit (inputs) tokei-src;
    }
  );

  lsd = import ../pkgs/userspace/lsd.nix (
    standaloneCommon
    // {
      inherit (inputs) lsd-src;
    }
  );

  shellharden = import ../pkgs/userspace/shellharden.nix (
    standaloneCommon
    // {
      inherit (inputs) shellharden-src;
    }
  );

  smith = import ../pkgs/userspace/smith.nix (
    standaloneCommon
    // {
      inherit (inputs) smith-src;
    }
  );

  strace-redox = import ../pkgs/userspace/strace-redox.nix (
    standaloneCommon
    // {
      inherit (inputs) strace-redox-src;
    }
  );

  findutils = import ../pkgs/userspace/findutils.nix (
    standaloneCommon
    // {
      inherit (inputs) findutils-src;
    }
  );

  contain = import ../pkgs/userspace/contain.nix (
    standaloneCommon
    // {
      inherit (inputs) contain-src;
    }
  );

  pkgar = import ../pkgs/userspace/pkgar.nix (
    standaloneCommon
    // {
      inherit (inputs) pkgar-src;
    }
  );

  # redox-ssh disabled: rustc-serialize dep doesn't compile on recent Rust nightly
  # redox-ssh = import ../pkgs/userspace/redox-ssh.nix (
  #   standaloneCommon
  #   // {
  #     inherit (inputs) redox-ssh-src;
  #   }
  # );

  exampled = import ../pkgs/userspace/exampled.nix (
    standaloneCommon
    // {
      inherit (inputs) exampled-src;
    }
  );

  redox-games = import ../pkgs/userspace/games.nix (
    standaloneCommon
    // {
      inherit (inputs) games-src;
    }
  );

  # === C Libraries (cross-compiled static libs for Redox) ===

  cLibCommon = {
    inherit pkgs lib redoxTarget;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs;
  };

  # === Data packages (no compilation) ===

  ca-certificates = import ../pkgs/userspace/ca-certificates.nix {
    inherit pkgs lib;
    inherit (inputs) ca-certificates-src;
  };

  terminfo = import ../pkgs/userspace/terminfo.nix {
    inherit pkgs lib;
    inherit (inputs) terminfo-src;
  };

  netdb = import ../pkgs/userspace/netdb.nix {
    inherit pkgs lib;
    inherit (inputs) netdb-src;
  };

  # === Additional Rust packages ===

  bottom = import ../pkgs/userspace/bottom.nix (
    standaloneCommon
    // {
      inherit (inputs) bottom-src;
    }
  );

  onefetch = import ../pkgs/userspace/onefetch.nix (
    standaloneCommon
    // {
      inherit (inputs) onefetch-src;
    }
  );

  # === C Libraries (cross-compiled static libs for Redox) ===

  redox-zlib = import ../pkgs/userspace/zlib.nix cLibCommon;

  redox-zstd = import ../pkgs/userspace/zstd-redox.nix cLibCommon;

  redox-expat = import ../pkgs/userspace/expat-redox.nix cLibCommon;

  redox-openssl = import ../pkgs/userspace/openssl-redox.nix (
    cLibCommon
    // {
      inherit (inputs) openssl-redox-src;
    }
  );

  redox-curl = import ../pkgs/userspace/curl-redox.nix (
    cLibCommon
    // {
      inherit redox-zlib redox-openssl;
    }
  );

  redox-ncurses = import ../pkgs/userspace/ncurses-redox.nix cLibCommon;

  redox-readline = import ../pkgs/userspace/readline-redox.nix (
    cLibCommon
    // {
      inherit redox-ncurses;
    }
  );

  # === Self-hosting: C binaries cross-compiled for Redox ===

  gnu-make = import ../pkgs/userspace/gnu-make.nix cLibCommon;

  redox-bash = import ../pkgs/userspace/bash-redox.nix (
    cLibCommon
    // {
      inherit redox-readline redox-ncurses;
    }
  );

  redox-libpng = import ../pkgs/userspace/libpng-redox.nix (
    cLibCommon
    // {
      inherit redox-zlib;
    }
  );

  redox-pcre2 = import ../pkgs/userspace/pcre2-redox.nix cLibCommon;

  redox-freetype2 = import ../pkgs/userspace/freetype2-redox.nix (
    cLibCommon
    // {
      inherit redox-zlib redox-libpng;
    }
  );

  redox-sqlite3 = import ../pkgs/userspace/sqlite3-redox.nix cLibCommon;

  # === Tier 1 foundation libraries ===

  redox-libiconv = import ../pkgs/userspace/libiconv-redox.nix cLibCommon;

  redox-bzip2 = import ../pkgs/userspace/bzip2-redox.nix cLibCommon;

  redox-lz4 = import ../pkgs/userspace/lz4-redox.nix cLibCommon;

  redox-xz = import ../pkgs/userspace/xz-redox.nix cLibCommon;

  redox-libffi = import ../pkgs/userspace/libffi-redox.nix cLibCommon;

  redox-libjpeg = import ../pkgs/userspace/libjpeg-redox.nix cLibCommon;

  redox-libgif = import ../pkgs/userspace/libgif-redox.nix cLibCommon;

  redox-pixman = import ../pkgs/userspace/pixman-redox.nix cLibCommon;

  redox-gettext = import ../pkgs/userspace/gettext-redox.nix (
    cLibCommon
    // {
      inherit redox-libiconv;
    }
  );

  redox-libtiff = import ../pkgs/userspace/libtiff-redox.nix (
    cLibCommon
    // {
      inherit redox-zlib redox-libjpeg;
    }
  );

  redox-libwebp = import ../pkgs/userspace/libwebp-redox.nix (
    cLibCommon
    // {
      inherit redox-zlib redox-libpng redox-libjpeg;
    }
  );

  redox-harfbuzz = import ../pkgs/userspace/harfbuzz-redox.nix (
    cLibCommon
    // {
      inherit redox-freetype2 redox-zlib redox-libpng;
    }
  );

  # ---- Graphics stack ----

  redox-glib = import ../pkgs/userspace/glib-redox.nix (
    cLibCommon
    // {
      inherit
        redox-zlib
        redox-libffi
        redox-libiconv
        redox-gettext
        redox-pcre2
        ;
    }
  );

  redox-fontconfig = import ../pkgs/userspace/fontconfig-redox.nix (
    cLibCommon
    // {
      inherit
        redox-expat
        redox-freetype2
        redox-libpng
        redox-zlib
        ;
    }
  );

  redox-fribidi = import ../pkgs/userspace/fribidi-redox.nix cLibCommon;

  # === Self-hosting: LLVM toolchain ===

  redox-libcxx = import ../pkgs/userspace/libcxx-redox.nix cLibCommon;

  redox-llvm = import ../pkgs/userspace/llvm-redox.nix (
    cLibCommon
    // {
      inherit redox-libcxx redox-zstd;
    }
  );

  redox-git = import ../pkgs/userspace/git-redox.nix (
    cLibCommon
    // {
      inherit
        redox-curl
        redox-expat
        redox-openssl
        redox-zlib
        ;
    }
  );

  redox-cmake = import ../pkgs/userspace/cmake-redox.nix (
    cLibCommon
    // {
      inherit
        redox-zlib
        redox-zstd
        redox-openssl
        redox-expat
        redox-bzip2
        redox-libcxx
        ;
    }
  );

  redox-diffutils = import ../pkgs/userspace/diffutils-redox.nix cLibCommon;

  redox-sed = import ../pkgs/userspace/sed-redox.nix cLibCommon;

  redox-patch = import ../pkgs/userspace/patch-redox.nix cLibCommon;

  redox-rustc = import ../pkgs/userspace/rustc-redox.nix (
    cLibCommon
    // {
      inherit
        redox-llvm
        redox-libcxx
        redox-openssl
        rustToolchain
        ;
    }
  );

  redox-libstdcxx-shim = import ../pkgs/userspace/libstdcxx-shim.nix (
    cLibCommon
    // {
      inherit redox-libcxx;
    }
  );

  redox-sysroot = import ../pkgs/userspace/redox-sysroot.nix {
    inherit pkgs lib;
    inherit (modularPkgs.system) relibc;
    inherit redoxTarget redox-llvm redox-libcxx;
    rustc-redox = redox-rustc;
  };

  lld-wrapper = import ../pkgs/userspace/lld-wrapper.nix {
    inherit
      pkgs
      lib
      rustToolchain
      redoxTarget
      ;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs;
  };

  proc-dump = import ../pkgs/userspace/proc-dump.nix {
    inherit
      pkgs
      lib
      rustToolchain
      redoxTarget
      ;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs;
  };

  waitpid-stress = import ../pkgs/userspace/waitpid-stress.nix {
    inherit
      pkgs
      lib
      rustToolchain
      redoxTarget
      ;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs;
  };

  # pkgutils disabled: ring crate needs pregenerated assembly from git source
  # pkgutils = import ../pkgs/userspace/pkgutils.nix (
  #   standaloneCommon
  #   // {
  #     inherit (inputs) pkgutils-src;
  #   }
  # );

  sysroot = pkgs.symlinkJoin {
    name = "redox-sysroot";
    paths = [
      rustToolchain
      modularPkgs.system.relibc
    ];
  };

in
{
  packages = {
    # Host tools
    inherit (modularPkgs.host) cookbook redoxfs installer;
    fstools = modularPkgs.host.fstools;

    # System components
    inherit (modularPkgs.system)
      relibc
      kernel
      bootloader
      base
      ;
    inherit sysroot sysrootVendor;

    # Userspace packages
    inherit (modularPkgs.userspace)
      ion
      helix
      binutils
      netutils
      netcfg-setup
      uutils
      redoxfsTarget
      extrautils
      ;
    inherit sodium;

    # Orbital graphics packages
    inherit
      orbdata
      orbital
      orbterm
      orbutils
      ;

    # User management
    inherit userutils;

    # CLI tools
    inherit
      ripgrep
      fd
      bat
      hexyl
      zoxide
      dust
      snix
      tokei
      lsd
      shellharden
      smith
      strace-redox
      findutils
      contain
      pkgar
      exampled
      redox-games
      ;

    # Data packages
    inherit
      ca-certificates
      terminfo
      netdb
      ;

    # Additional Rust CLI tools
    inherit
      bottom
      ;
    # onefetch disabled: proc-macro2 1.0.46 uses removed proc_macro_span_shrink feature

    # C Libraries (cross-compiled static libs)
    inherit
      redox-zlib
      redox-zstd
      redox-expat
      redox-openssl
      redox-curl
      redox-ncurses
      redox-readline
      redox-libpng
      redox-pcre2
      redox-freetype2
      redox-sqlite3
      # Tier 1 foundation libraries
      redox-libiconv
      redox-bzip2
      redox-lz4
      redox-xz
      redox-libffi
      redox-libjpeg
      redox-libgif
      redox-pixman
      redox-gettext
      redox-libtiff
      redox-libwebp
      redox-harfbuzz
      # Graphics stack
      redox-glib
      redox-fontconfig
      redox-fribidi
      ;

    # Self-hosting: build tools and shells
    inherit
      gnu-make
      redox-bash
      redox-git
      redox-diffutils
      redox-sed
      redox-patch
      redox-cmake
      ;

    # Self-hosting: LLVM + Rust toolchain
    inherit
      redox-libcxx
      redox-libstdcxx-shim
      redox-llvm
      redox-rustc
      redox-sysroot
      lld-wrapper
      proc-dump
      waitpid-stress
      ;

    # Infrastructure (needed by module system)
    inherit (modularPkgs.infrastructure) initfsTools bootstrap;

    # Default package
    default = modularPkgs.host.fstools;
  };

  # Expose build environment for other modules via legacyPackages
  legacyPackages = {
    inherit rustToolchain craneLib;
  };
}
