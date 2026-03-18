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

  # unit2nix vendor function — parses Cargo.lock at eval time, no vendorHash needed
  unit2nixVendor = import "${inputs.unit2nix}/lib/vendor.nix";

  # Common args for all standalone packages (mk-userspace path)
  standaloneCommon = {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      unit2nixVendor
      ;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs vendor;
  };

  # === Per-crate cross-compilation via unit2nix ===
  #
  # Builds Rust packages from pre-generated JSON build plans.
  # Each crate is a separate Nix derivation = per-crate caching.
  # Replaces the old mk-userspace.nix whole-cargo-build path for
  # packages that have build plans checked in.

  buildFromUnitGraph = import "${inputs.unit2nix}/lib/build-from-unit-graph.nix";

  redoxBRC = import ../lib/redox-buildRustCrate.nix {
    inherit pkgs lib rustToolchain;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs;
  };

  # Kernel buildRustCrate for x86_64-unknown-kernel target.
  kernelTargetSpec = "${inputs.kernel-src}/targets/x86_64-unknown-kernel.json";
  kernelBRC = import ../lib/kernel-buildRustCrate.nix {
    inherit
      pkgs
      lib
      rustToolchain
      kernelTargetSpec
      ;
  };

  # Host buildRustCrate for build scripts and proc-macros (run on build machine).
  hostBRC = pkgs.buildRustCrate.override {
    rustc = rustToolchain;
    cargo = rustToolchain;
  };

  # Cross-compilation dispatch: target crates → redoxBRC, build-time → hostBRC.
  # hostPkgs has a marker to distinguish from crossPkgs in the dispatch function.
  hostPkgs = pkgs // {
    __isHostPkgs = true;
    buildPackages = hostPkgs;
  };
  crossPkgs = pkgs // {
    buildPackages = hostPkgs;
  };
  buildRustCrateForPkgs = cratePkgs: if cratePkgs ? __isHostPkgs then hostBRC else redoxBRC;

  # Kernel cross-compilation dispatch: target crates → kernelBRC, build-time → hostBRC.
  kernelCrossPkgs = pkgs // {
    buildPackages = hostPkgs;
  };
  kernelBRCForPkgs = cratePkgs: if cratePkgs ? __isHostPkgs then hostBRC else kernelBRC;

  # Build a package from a checked-in JSON build plan.
  mkCrossPackage =
    {
      pname,
      src,
      plan,
      member ? pname,
      extraCrateOverrides ? { },
    }:
    let
      ws = buildFromUnitGraph {
        inherit extraCrateOverrides;
        pkgs = crossPkgs;
        inherit src;
        resolvedJson = plan;
        buildRustCrateForPkgs = buildRustCrateForPkgs;
        skipStalenessCheck = true;
        skipTargetCheck = true;
      };
    in
    ws.workspaceMembers.${member}.build // { inherit pname; };

  # Shared crate-level overrides for cross-builds.
  cratePatches = {
    # rustix: force libc backend to avoid linux_raw_sys dependency.
    # Needed for packages whose plans exclude linux_raw_sys.
    rustixOverride = {
      rustix = _: {
        CARGO_CFG_RUSTIX_USE_LIBC = "1";
        postPatch = ''
          sed -i 's/use_feature("linux_like");/if !cfg_use_libc { use_feature("linux_like"); }/' build.rs
          sed -i 's/use_feature("linux_kernel");/if !cfg_use_libc { use_feature("linux_kernel"); }/' build.rs
        '';
      };
    };
    # faccess: redirect Redox to generic fallback (faccessat not in relibc).
    faccessOverride = {
      faccess = _: {
        postPatch = ''
          sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' src/lib.rs
          sed -i 's/#\[cfg(not(any(unix, windows)))\]/#[cfg(any(target_os = "redox", not(any(unix, windows))))]/g' src/lib.rs
        '';
      };
    };
    # fd-find: nix crate's User/Group are gated out for Redox.
    fdOverride = {
      fd-find = _: {
        postPatch = ''
          for f in src/filter/mod.rs src/config.rs src/main.rs src/cli.rs src/walk.rs; do
            if [ -f "$f" ]; then
              sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' "$f"
            fi
          done
        '';
      };
    };
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

  # === Per-crate cross-compiled packages (unit2nix) ===
  #
  # These use pre-generated JSON build plans for per-crate Nix caching.
  # Each crate is a separate derivation — unchanged deps reuse store paths.

  ripgrep = mkCrossPackage {
    pname = "ripgrep";
    src = inputs.ripgrep-src;
    plan = ../pkgs/infrastructure/ripgrep-redox-plan.json;
    member = "ripgrep";
  };

  fd = mkCrossPackage {
    pname = "fd";
    src = inputs.fd-src;
    plan = ../pkgs/infrastructure/fd-redox-plan.json;
    member = "fd-find";
    extraCrateOverrides = cratePatches.faccessOverride // cratePatches.fdOverride;
  };

  bat = mkCrossPackage {
    pname = "bat";
    src = inputs.bat-src;
    plan = ../pkgs/infrastructure/bat-redox-plan.json;
    member = "bat";
  };

  hexyl = mkCrossPackage {
    pname = "hexyl";
    src = inputs.hexyl-src;
    plan = ../pkgs/infrastructure/hexyl-redox-plan.json;
    member = "hexyl";
  };

  zoxide = mkCrossPackage {
    pname = "zoxide";
    src = inputs.zoxide-src;
    plan = ../pkgs/infrastructure/zoxide-redox-plan.json;
    member = "zoxide";
  };

  dust = mkCrossPackage {
    pname = "dust";
    src = inputs.dust-src;
    plan = ../pkgs/infrastructure/dust-redox-plan.json;
    member = "du-dust";
  };

  # === Per-crate kernel build (unit2nix) ===
  #
  # Builds the Redox kernel with per-crate Nix caching. When only kernel
  # source changes, the 38 registry deps + 3 stdlib crates are cached,
  # rebuilding only kernel + rmm (~10-15s instead of ~74s).
  #
  # mkKernelPerCrate: parameterized builder for kernel variants.
  #   extraFeatures: additional Cargo features (e.g. ["syscall_debug"])
  #   srcPatch: optional source patching function (src -> patched src derivation)
  mkKernelPerCrate =
    {
      extraFeatures ? [ ],
      srcPatch ? null,
      pnameSuffix ? "",
    }:
    let
      # The kernel source with patches applied (same as kernel.nix's patchedSrc)
      baseSrc = modularPkgs.system.kernel.src;
      patchedKernelSrc = if srcPatch != null then srcPatch baseSrc else baseSrc;
      rustSrcPath = "${rustToolchain}/lib/rustlib/src/rust";

      ws = buildFromUnitGraph {
        pkgs = kernelCrossPkgs;
        src = patchedKernelSrc;
        resolvedJson = ../pkgs/system/kernel-build-plan.json;
        buildRustCrateForPkgs = kernelBRCForPkgs;
        skipStalenessCheck = true;
        skipTargetCheck = true;
        inherit rustSrcPath;
        extraCrateOverrides = {
          # The kernel crate needs nasm for build.rs and linker script args.
          kernel = attrs: {
            nativeBuildInputs = (attrs.nativeBuildInputs or [ ]) ++ [
              pkgs.nasm
            ];
            # Append extra features (e.g. syscall_debug) to the resolved set.
            features = (attrs.features or [ ]) ++ extraFeatures;
            # Linker script and page size args passed to rustc for the final link.
            extraRustcOpts = (attrs.extraRustcOpts or [ ]) ++ [
              "-C"
              "link-arg=-T"
              "-C"
              "link-arg=${patchedKernelSrc}/linkers/x86_64.ld"
              "-C"
              "link-arg=-z"
              "-C"
              "link-arg=max-page-size=0x1000"
            ];
            # Prevent fixup phase from stripping debug info — we split it
            # into a .sym file in the post-processing derivation.
            dontStrip = true;
            # buildRustCrate needs the assembly files for the build script
            postPatch = ''
              # Ensure assembly files are in the right place
              if [ ! -d src/asm ]; then
                echo "warning: no src/asm directory" >&2
              fi
            '';
          };
        };
      };

      kernelCrate = ws.workspaceMembers.kernel.build;
    in
    # Post-process: strip debug info into separate .sym file
    pkgs.stdenv.mkDerivation {
      pname = "redox-kernel-percrate${pnameSuffix}";
      version = "unstable";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.llvmPackages.llvm ];
      installPhase = ''
        mkdir -p $out/boot

        # Find the kernel binary produced by buildRustCrate
        KBIN=$(find ${kernelCrate} -name "kernel" -type f | head -1)
        if [ -z "$KBIN" ]; then
          echo "ERROR: kernel binary not found in ${kernelCrate}" >&2
          find ${kernelCrate} -type f | head -20 >&2
          exit 1
        fi

        llvm-objcopy --only-keep-debug "$KBIN" $out/boot/kernel.sym
        llvm-objcopy --strip-debug "$KBIN" $out/boot/kernel
      '';
    };

  # Standard kernel (no extra features)
  kernelPerCrate = mkKernelPerCrate { };

  # Kernel with syscall_debug: traces syscalls to serial console.
  # The debug.rs patch removes the `false &&` guard. By default traces
  # all processes; pass debugProcesses to filter.
  mkKernelSyscallDebug =
    {
      debugProcesses ? [ ],
    }:
    let
      # Build the process filter expression for debug.rs.
      # Empty list = match everything (.contains("") is always true).
      # Single process = .contains("name")
      # Multiple = .contains("a") || .contains("b") || ...
      filterNames = if debugProcesses == [ ] then [ "" ] else debugProcesses;
      filterExpr = builtins.concatStringsSep " || " (map (name: ''.contains("${name}")'') filterNames);
    in
    mkKernelPerCrate {
      extraFeatures = [ "syscall_debug" ];
      pnameSuffix = "-syscall-debug";
      srcPatch =
        src:
        pkgs.stdenv.mkDerivation {
          name = "kernel-src-syscall-debug";
          inherit src;
          phases = [
            "unpackPhase"
            "patchPhase"
            "installPhase"
          ];
          postPatch = ''
                      # Rewrite the do_debug expression in debug_start().
                      # Replace the entire `if false && ...contains("init")` block
                      # with our filter expression.
                      ${pkgs.python3}/bin/python3 -c "
            import re, sys

            path = 'src/syscall/debug.rs'
            with open(path) as f:
                src = f.read()

            # Match the do_debug assignment block:
            #   let do_debug = if false
            #       && crate::context::current()
            #           .read(token.token())
            #           .name
            #           .contains(\"init\")
            old_pattern = (
                r'let do_debug = if false\n'
                r'\s+&& crate::context::current\(\)\n'
                r'\s+\.read\(token\.token\(\)\)\n'
                r'\s+\.name\n'
                r'\s+\.contains\([^)]+\)'
            )

            new_code = (
                'let do_debug = if crate::context::current()\n'
                '            .read(token.token())\n'
                '            .name\n'
                '            ${filterExpr}'
            )

            result = re.sub(old_pattern, new_code, src)
            if result == src:
                print('WARNING: pattern not found in debug.rs, trying fallback', file=sys.stderr)
                result = src.replace('let do_debug = if false', 'let do_debug = if true')

            with open(path, 'w') as f:
                f.write(result)
            print('Patched debug.rs for syscall tracing')
            "
          '';
          installPhase = "cp -r . $out";
        };
    };

  # Default syscall debug kernel: traces all processes.
  kernelSyscallDebug = mkKernelSyscallDebug { };

  # === Per-crate base build (unit2nix) ===
  #
  # Builds the 46 base system binaries (init, drivers, daemons) with
  # per-crate Nix caching. Changing one driver rebuilds only that crate
  # and its direct dependents — the ~170 registry deps are cached.
  basePerCrate =
    let
      patchedBaseSrc = modularPkgs.system.base.src;

      # External path deps: the patched Cargo.toml replaces git deps with
      # absolute /nix/store paths. Pure evaluation can't resolve those from
      # the JSON, so we override src per crate to point to flake inputs.
      externalSrcOverrides = {
        fdt = _: {
          src = inputs.fdt-src;
        };
        redox-log = _: {
          src = inputs.redox-log-src;
        };
        drm = _: {
          src = inputs.drm-rs-src;
        };
        drm-ffi = _: {
          src = inputs.drm-rs-src + "/drm-ffi";
        };
        drm-sys = _: {
          src = inputs.drm-rs-src + "/drm-ffi/drm-sys";
        };
        # redox-rt uses `#[path = "../../src/platform/auxv_defs.rs"]` so it
        # needs the full relibc source tree, not just its subdirectory.
        # buildRustCrate unpacks into a flat dir and compiles from there,
        # so we give it the whole tree and set workspace_member to navigate.
        generic-rt = _: {
          src = inputs.relibc-src;
          workspace_member = "generic-rt";
        };
        redox-rt = _: {
          src = inputs.relibc-src;
          workspace_member = "redox-rt";
        };
      };

      ws = buildFromUnitGraph {
        pkgs = crossPkgs;
        src = patchedBaseSrc;
        resolvedJson = ../pkgs/system/base-build-plan.json;
        buildRustCrateForPkgs = buildRustCrateForPkgs;
        skipStalenessCheck = true;
        skipTargetCheck = true;
        extraCrateOverrides = externalSrcOverrides;
      };

      # Workspace members that produce binaries (46 total).
      # Lib-only members (common, config, daemon, etc.) are internal deps.
      binMembers = [
        "ac97d"
        "acpid"
        "ahcid"
        "audiod"
        "bcm2835-sdhcid"
        "bgad"
        "e1000d"
        "fbbootlogd"
        "fbcond"
        "hwd"
        "ided"
        "ihdad"
        "ihdgd"
        "init"
        "inputd"
        "ipcd"
        "ixgbed"
        "lived"
        "logd"
        "nvmed"
        "pcid"
        "pcid-spawner"
        "ps2d"
        "ptyd"
        "ramfs"
        "randd"
        "redox-initfs-tools"
        "redox_netstack"
        "redoxerd"
        "rtcd"
        "rtl8139d"
        "rtl8168d"
        "sb16d"
        "usbctl"
        "usbhidd"
        "usbhubd"
        "usbscsid"
        "vboxd"
        "vesad"
        "virtio-blkd"
        "virtio-fsd"
        "virtio-gpud"
        "virtio-netd"
        "xhcid"
        "zerod"
      ];

      memberBuilds = map (name: ws.workspaceMembers.${name}.build) binMembers;
    in
    # Collect all workspace member binaries into a single output.
    # Must copy (not symlink) because Redox can't follow symlinks to
    # /nix/store paths — the store doesn't exist on the target rootfs.
    pkgs.runCommand "redox-base-percrate-unstable" { } ''
      mkdir -p $out/bin
      for pkg in ${lib.concatMapStringsSep " " toString memberBuilds}; do
        for bin in "$pkg"/bin/*; do
          [ -f "$bin" ] && cp "$bin" $out/bin/
        done
      done
    '';

  snix = mkCrossPackage {
    pname = "snix-redox";
    src = ../../snix-redox;
    plan = ../pkgs/userspace/snix-build-plan.json;
    member = "snix-redox";
  };

  # === Per-crate helix build (unit2nix) ===
  #
  # 191 crates, 11 workspace members. Only helix-term produces a binary (hx).
  # Renamed to `helix` in the output to match the existing package interface.
  helixPerCrate =
    let
      ws = buildFromUnitGraph {
        pkgs = crossPkgs;
        src = inputs.helix-src;
        resolvedJson = ../pkgs/userspace/helix-build-plan.json;
        buildRustCrateForPkgs = buildRustCrateForPkgs;
        skipStalenessCheck = true;
        skipTargetCheck = true;
        extraCrateOverrides = {
          helix-term = _: {
            # Prevent build.rs from trying to fetch+compile tree-sitter grammars
            HELIX_DISABLE_AUTO_GRAMMAR_BUILD = "1";
          };
          # helix-loader and helix-view include files from workspace root
          # (../../languages.toml, ../../theme.toml) via include_bytes!().
          # Give them the full workspace source so relative paths resolve.
          helix-loader = _: {
            src = inputs.helix-src;
            workspace_member = "helix-loader";
          };
          helix-view = _: {
            src = inputs.helix-src;
            workspace_member = "helix-view";
          };
          # tree-sitter compiles C code via cc crate. Must cross-compile
          # for Redox, not the host — otherwise picks up glibc headers
          # and references __fprintf_chk etc. that don't exist in relibc.
          tree-sitter = _: {
            CC_x86_64_unknown_redox = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
            CFLAGS_x86_64_unknown_redox = builtins.concatStringsSep " " [
              "--target=${redoxTarget}"
              "-D__redox__"
              "-U_FORTIFY_SOURCE"
              "-D_FORTIFY_SOURCE=0"
              "-I${modularPkgs.system.relibc}/${redoxTarget}/include"
              "--sysroot=${modularPkgs.system.relibc}/${redoxTarget}"
            ];
          };
        };
      };
      hxBin = ws.workspaceMembers.helix-term.build;
    in
    # Rename hx → helix to match existing package interface
    pkgs.runCommand "helix" { } ''
      mkdir -p $out/bin
      cp ${hxBin}/bin/hx $out/bin/helix
    '';

  tokei = mkCrossPackage {
    pname = "tokei";
    src = inputs.tokei-src;
    plan = ../pkgs/infrastructure/tokei-redox-plan.json;
    member = "tokei";
  };

  lsd = mkCrossPackage {
    pname = "lsd";
    src = inputs.lsd-src;
    plan = ../pkgs/infrastructure/lsd-redox-plan.json;
    member = "lsd";
    extraCrateOverrides = cratePatches.rustixOverride;
  };

  shellharden = mkCrossPackage {
    pname = "shellharden";
    src = inputs.shellharden-src;
    plan = ../pkgs/infrastructure/shellharden-redox-plan.json;
    member = "shellharden";
  };

  smith = mkCrossPackage {
    pname = "smith";
    src = inputs.smith-src;
    plan = ../pkgs/infrastructure/smith-redox-plan.json;
    member = "smith";
  };

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

  exampled = mkCrossPackage {
    pname = "exampled";
    src = inputs.exampled-src;
    plan = ../pkgs/infrastructure/exampled-redox-plan.json;
    member = "exampled";
  };

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

  # === Per-crate ion build (unit2nix) ===
  ionPerCrate = mkCrossPackage {
    pname = "ion-shell";
    src = inputs.ion-src;
    plan = ../pkgs/userspace/ion-build-plan.json;
    member = "ion-shell";
    extraCrateOverrides = {
      ion-shell = _: {
        # build.rs reads git_revision.txt; without it, tries `git rev-parse`
        postPatch = ''
          echo "nix-build" > git_revision.txt
        '';
      };
      # decimal crate compiles C code (decQuad.c) via cc crate.
      # Must cross-compile for Redox to avoid glibc FORTIFY refs.
      decimal = _: {
        CC_x86_64_unknown_redox = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
        CFLAGS_x86_64_unknown_redox = builtins.concatStringsSep " " [
          "--target=${redoxTarget}"
          "-D__redox__"
          "-U_FORTIFY_SOURCE"
          "-D_FORTIFY_SOURCE=0"
          "-I${modularPkgs.system.relibc}/${redoxTarget}/include"
          "--sysroot=${modularPkgs.system.relibc}/${redoxTarget}"
        ];
      };
    };
  };

  # === Per-crate extrautils build (unit2nix) ===
  #
  # 18 binaries from a single workspace member. buildRustCrate produces
  # all binaries in $out/bin/ automatically from crateBin entries.
  # extrautils source needs rust-lzma and tar removed (no liblzma for Redox).
  extrautilsPatchedSrc = pkgs.runCommand "extrautils-patched" { } ''
    cp -r ${inputs.extrautils-src} $out
    chmod -R u+w $out
    cd $out
    sed -i '/^rust-lzma/d' Cargo.toml
    sed -i '/^\[features\]/,/^\[/{ /^\[features\]/d; /^\[/!d; }' Cargo.toml
    sed -i '/^\[\[bin\]\]$/,/^path = /{
      /name = "tar"/,/^path = /{d}
    }' Cargo.toml
    sed -i '/^\[\[bin\]\]$/{N; /\n$/d}' Cargo.toml
  '';

  extrautilsPerCrate = mkCrossPackage {
    pname = "extrautils";
    src = extrautilsPatchedSrc;
    plan = ../pkgs/userspace/extrautils-build-plan.json;
    member = "extrautils";
  };

  # === Per-crate userutils build (unit2nix) ===
  #
  # 12 binaries (getty, login, passwd, sudo, etc.)
  # userutils has generic-rt and redox-rt from relibc as git deps — they're
  # prefetched by unit2nix so no source overrides needed.
  userutilsPerCrate = mkCrossPackage {
    pname = "userutils";
    src = inputs.userutils-src;
    plan = ../pkgs/userspace/userutils-build-plan.json;
    member = "userutils";
    extraCrateOverrides = {
      # redox-rt uses #[path = "../../src/platform/auxv_defs.rs"] —
      # needs full relibc source tree, not just the subDir.
      redox-rt = _: {
        src = inputs.relibc-src;
        workspace_member = "redox-rt";
      };
      generic-rt = _: {
        src = inputs.relibc-src;
        workspace_member = "generic-rt";
      };
    };
  };

  # === Per-crate bootloader build (unit2nix) ===
  #
  # UEFI bootloader targeting x86_64-unknown-uefi with --build-std.
  # Needs a dedicated buildRustCrate like the kernel (no_std, no CRT).
  bootloaderPerCrate =
    let
      uefiBRC = import ../lib/kernel-buildRustCrate.nix {
        inherit pkgs lib rustToolchain;
        # x86_64-unknown-uefi is a built-in rustc target (no JSON spec)
        kernelTargetSpec = "x86_64-unknown-uefi";
      };
      uefiBRCForPkgs = cratePkgs: if cratePkgs ? __isHostPkgs then hostBRC else uefiBRC;
      uefiCrossPkgs = pkgs // {
        buildPackages = hostPkgs;
      };

      ws = buildFromUnitGraph {
        pkgs = uefiCrossPkgs;
        src = inputs.bootloader-src;
        resolvedJson = ../pkgs/system/bootloader-build-plan.json;
        buildRustCrateForPkgs = uefiBRCForPkgs;
        skipStalenessCheck = true;
        skipTargetCheck = true;
        rustSrcPath = "${rustToolchain}/lib/rustlib/src/rust";
      };

      bootBin = ws.workspaceMembers.redox_bootloader.build;
    in
    # Post-process: wrap as $out/boot/EFI/BOOT/BOOTX64.EFI to match existing layout
    pkgs.runCommand "redox-bootloader-percrate-unstable" { } ''
      mkdir -p $out/boot/EFI/BOOT
      BIN=$(find ${bootBin} -name "bootloader" -type f | head -1)
      if [ -z "$BIN" ]; then
        echo "ERROR: bootloader binary not found in ${bootBin}" >&2
        find ${bootBin} -type f | head -20 >&2
        exit 1
      fi
      cp "$BIN" $out/boot/EFI/BOOT/BOOTX64.EFI
    '';

  pkgutils = import ../pkgs/userspace/pkgutils.nix (
    standaloneCommon
    // {
      inherit (inputs) pkgutils-src ring-redox-src;
    }
  );

  # === Bare metal / ecosystem library crates ===

  gdb-protocol = import ../pkgs/userspace/gdb-protocol.nix (
    standaloneCommon
    // {
      inherit (inputs) gdb-protocol-src;
    }
  );

  redox-intelflash = import ../pkgs/userspace/intelflash.nix (
    standaloneCommon
    // {
      inherit (inputs) intelflash-src;
    }
  );

  redox-buffer-pool = import ../pkgs/userspace/buffer-pool.nix (
    standaloneCommon
    // {
      inherit (inputs) buffer-pool-src;
    }
  );

  gdbstub = import ../pkgs/userspace/gdbstub.nix standaloneCommon;

  # === Host tools (run on Linux, not on Redox) ===

  pkgar-repo = import ../pkgs/host/pkgar-repo.nix {
    inherit pkgs lib;
    inherit (inputs) pkgar-src;
  };

  redox-kprofiling = import ../pkgs/host/kprofiling.nix {
    inherit pkgs lib rustToolchain;
    inherit (inputs) kprofiling-src;
  };

  redoxer = import ../pkgs/host/redoxer.nix {
    inherit pkgs lib;
    inherit (inputs) redoxer-src;
  };

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
    helix = helixPerCrate;
    ion = ionPerCrate;
    userutils = userutilsPerCrate;
    inherit (modularPkgs.userspace)
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
      pkgutils
      exampled
      redox-games
      ;

    # Bare metal / ecosystem libraries
    inherit
      gdb-protocol
      redox-intelflash
      redox-buffer-pool
      gdbstub
      ;

    # Host tools (run on Linux)
    inherit
      pkgar-repo
      redox-kprofiling
      redoxer
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

    # Per-crate builds (unit2nix incremental)
    inherit kernelPerCrate basePerCrate kernelSyscallDebug;

    # Default package is set in system.nix (diskImageGraphical)
  };

  # Expose build environment for other modules via legacyPackages
  legacyPackages = {
    inherit rustToolchain craneLib;
    # Parameterized kernel builder for custom syscall debug variants.
    # Usage: mkKernelSyscallDebug { debugProcesses = ["cargo" "rustc"]; }
    inherit mkKernelSyscallDebug;
  };
}
