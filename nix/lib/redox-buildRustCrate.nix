# Per-crate cross-compilation to Redox via buildRustCrate.
#
# Returns a buildRustCrate function that cross-compiles individual crates
# for x86_64-unknown-redox with per-crate Nix caching. Used with unit2nix's
# buildFromUnitGraph.
#
# Strategy:
# 1. Override stdenv so hostPlatform != buildPlatform (triggers --target flag)
# 2. Inject Redox RUSTFLAGS via extraRustcOpts on every crate
# 3. Use a linker wrapper that invokes ld.lld directly
#
# The linker wrapper is set as stdenv.cc/bin/cc for buildRustCrate.
# rustc's x86_64-unknown-redox target uses "gnu-cc" linker flavor, so it
# passes GCC-driver-compatible args (-m64, -Wl,..., etc.). Our wrapper
# translates these to ld.lld-compatible args, adds CRT objects + sysroot,
# and invokes lld directly.

{
  pkgs,
  lib,
  rustToolchain,
  relibc,
  stubLibs,
  redoxTarget ? "x86_64-unknown-redox",
}:

let
  lld = pkgs.llvmPackages.lld;
  sysroot = "${relibc}/${redoxTarget}";

  # Linker wrapper: translates GCC-driver args from rustc into ld.lld args.
  #
  # rustc (gnu-cc flavor) passes args like:
  #   cc -m64 foo.o -Wl,--as-needed -Wl,-Bstatic <rlibs> -lgcc_eh
  #   -lc -Wl,-Bdynamic -lgcc -Wl,--gc-sections -static -no-pie
  #   -Wl,-z,relro,-z,now -Wl,-O1 -nodefaultlibs -o target/bin/rg
  #
  # We translate: strip -Wl, prefixes, filter gcc-specific flags, add CRT.
  redoxLinker = pkgs.writeShellScript "redox-ld" ''
    args=()
    # Add CRT objects and library paths first
    args+=("${sysroot}/lib/crt0.o")
    args+=("${sysroot}/lib/crti.o")
    args+=("-L${sysroot}/lib")
    args+=("-L${stubLibs}/lib")

    for arg in "$@"; do
      case "$arg" in
        -Wl,*)
          # Split comma-separated -Wl, args into individual ld flags
          rest="''${arg#-Wl,}"
          while [ -n "$rest" ]; do
            piece="''${rest%%,*}"
            if [ "$piece" = "$rest" ]; then
              rest=""
            else
              rest="''${rest#*,}"
            fi
            args+=("$piece")
          done
          ;;
        -lgcc) ;; # Symbols are in libgcc_eh.a (in stubLibs)
        -no-pie) ;; # Incompatible with -static
        -m64) ;; # x86_64 is implied by the ELF objects
        -nodefaultlibs) ;; # GCC-specific, not relevant for lld
        *) args+=("$arg") ;;
      esac
    done

    # Add CRT finale and dedup control
    args+=("-lc")
    args+=("${sysroot}/lib/crtn.o")
    args+=("--allow-multiple-definition")

    exec ${lld}/bin/ld.lld "''${args[@]}"
  '';

  # Make the wrapper available as /bin/cc so buildRustCrate finds it
  # via stdenv.cc/bin/${targetPrefix}cc
  redoxCcDir = pkgs.runCommand "redox-cc" { } ''
    mkdir -p $out/bin
    ln -s ${redoxLinker} $out/bin/cc
  '';

  # Minimal Redox host platform for buildRustCrate's cross-compilation checks.
  redoxHostPlatform = {
    config = redoxTarget;
    system = "x86_64-redox";
    linker = "cc";
    isLinux = false;
    isDarwin = false;
    isWindows = false;
    isx86_64 = true;
    is64bit = true;
    isILP32 = false;
    extensions = {
      library = ".a";
      executable = "";
      sharedLibrary = ".so";
    };
    parsed = {
      cpu = {
        name = "x86_64";
        bits = 64;
        significantByte.name = "littleEndian";
      };
      vendor.name = "unknown";
      kernel.name = "redox";
      abi.name = "";
    };
    rust = {
      rustcTarget = redoxTarget;
      rustcTargetSpec = redoxTarget;
      platform = {
        arch = "x86_64";
        os = "redox";
      };
    };
  };

  # Cross stdenv: hostPlatform = Redox, buildPlatform = native linux.
  # Triggers buildRustCrate to add --target x86_64-unknown-redox.
  crossStdenv = pkgs.stdenv // {
    hostPlatform = redoxHostPlatform;
    cc = redoxCcDir // {
      targetPrefix = "";
    };
    hasCC = true;
  };

  # RUSTFLAGS injected into every crate via extraRustcOpts.
  redoxExtraOpts = [
    "-C"
    "target-cpu=x86-64"
    "-C"
    "panic=abort"
    "-L"
    "${sysroot}/lib"
    "-L"
    "${stubLibs}/lib"
  ];

  # The base buildRustCrate with Redox cross-compilation support.
  baseBRC = pkgs.buildRustCrate.override {
    rustc = rustToolchain;
    cargo = rustToolchain;
    stdenv = crossStdenv;
  };

  # Wrap buildRustCrate to inject extraRustcOpts into every crate.
  # Uses __functor so the result is both callable and has .override.
  wrapBRC = brc: {
    __functor =
      _self: crateAttrs:
      brc (
        crateAttrs
        // {
          extraRustcOpts = (crateAttrs.extraRustcOpts or [ ]) ++ redoxExtraOpts;
        }
      );
    override = newArgs: wrapBRC (brc.override newArgs);
  };

in
wrapBRC baseBRC
