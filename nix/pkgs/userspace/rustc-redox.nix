# rustc + cargo — Rust compiler toolchain cross-compiled for Redox OS
#
# Cross-compiles the Rust compiler and Cargo for x86_64-unknown-redox.
# Uses the official Rust nightly source tarball (with vendored deps)
# and applies the Redox fork's patches on top.
#
# Bootstrap stages:
#   Stage 0: Host rustc (nightly-2025-10-03 from nixpkgs)
#   Stage 1: Built by stage 0, runs on host, can target Redox
#   Stage 2: Built by stage 1, runs ON Redox, targets Redox
#
# Patches from: gitlab.redox-os.org/redox-os/rust branch redox-2025-10-03
#   - available_parallelism: use sysconf(_SC_NPROCESSORS_ONLN) on Redox
#   - Sysroot fallback to / (instead of panic when sysroot not found)
#   - crt_static_allows_dylibs: true (upstream already correct, no patch needed)
#   - CMAKE_SYSTEM_NAME for Redox as UnixPaths
#
# LLVM: cross-compiled LLVM from llvm-redox.nix for stage 2,
# host LLVM for stage 1. A wrapper script mimics llvm-config.
#
# Output: rustc, cargo, rustdoc — static ELF for x86_64-unknown-redox

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-llvm,
  redox-libcxx,
  redox-openssl,
  stubLibs,
  rustToolchain,
  ...
}:

let
  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  sysroot = "${relibc}/${redoxTarget}";

  # Host LLVM (for stage 1 — builds run on the host)
  hostLlvmDev = pkgs.llvmPackages.llvm.dev;
  hostLlvmLib = pkgs.llvmPackages.llvm.lib;

  # Cross compilation tools
  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  cxx = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang++";
  ar = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
  ranlib = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib";

  # CC wrapper for cross-compiling C/C++ code for Redox
  ccWrapper = pkgs.writeShellScript "redox-cc" ''
    for arg in "$@"; do
      case "$arg" in
        -c|-S|-E|-M|-MM) exec ${cc} --target=${redoxTarget} --sysroot=${sysroot} -D__redox__ \
          -nostdlibinc -isystem ${sysroot}/include "$@" ;;
      esac
    done
    # Check if any arg is a .so (dynamic linking needed)
    NEEDS_DYNAMIC=false
    for arg in "$@"; do
      case "$arg" in
        *.so|*.so.*|-shared|-Bdynamic) NEEDS_DYNAMIC=true ;;
        -l) NEEDS_DYNAMIC=true ;;
      esac
    done

    if [ "$NEEDS_DYNAMIC" = "true" ]; then
      # Dynamic link: add dynamic linker path for PT_INTERP, keep libc static.
      # --export-dynamic: export all program symbols in the dynamic symbol table
      # so that shared libraries (librustc_driver.so, libstdc++.so.6, proc-macros)
      # resolve C/relibc symbols from the program binary instead of libc.so.
      #
      # Intercept Rust's version script to add __relibc_init_ns_fd to exported
      # symbols. Without this, the version script's "local: *;" hides the symbol,
      # preventing ld_so from injecting the process namespace fd into .so files.
      for arg in "$@"; do
        case "$arg" in
          -Wl,--version-script=*)
            vs="''${arg#-Wl,--version-script=}"
            if [ -f "$vs" ]; then
              ${pkgs.gnused}/bin/sed -i '/^[[:space:]]*local:/i\    __relibc_init_ns_fd;\n    __relibc_init_proc_fd;' "$vs"
            fi
            ;;
        esac
      done
      exec ${cc} --target=${redoxTarget} --sysroot=${sysroot} -D__redox__ \
        -nostdlib \
        ${sysroot}/lib/crt0.o ${sysroot}/lib/crti.o \
        "$@" \
        -L${sysroot}/lib -L${redox-libcxx}/lib -L${stubLibs}/lib \
        -lc++ -lc++abi -lunwind -l:libc.a -l:libpthread.a -lgcc \
        ${sysroot}/lib/crtn.o \
        -fuse-ld=lld \
        -Wl,--dynamic-linker=/lib/ld64.so.1 \
        -Wl,--export-dynamic \
        -Wl,--undefined-version
    else
      # Fully static link (cargo, etc.)
      exec ${cc} --target=${redoxTarget} --sysroot=${sysroot} -D__redox__ \
        -static -nostdlib \
        ${sysroot}/lib/crt0.o ${sysroot}/lib/crti.o \
        "$@" \
        -L${sysroot}/lib -L${redox-libcxx}/lib -L${stubLibs}/lib \
        -lc++ -lc++abi -lunwind -l:libc.a -l:libpthread.a -lgcc \
        ${sysroot}/lib/crtn.o \
        -fuse-ld=lld
    fi
  '';

  # Redox's relibc has locale_t, newlocale/freelocale/uselocale, isdigit_l etc.
  # but is MISSING: strtof_l, strtod_l, strtold_l, strtoll_l, strtoull_l,
  # snprintf_l, sscanf_l, asprintf_l. Provide stubs for only the missing ones.
  localeStubs = pkgs.runCommand "redox-locale-stubs" { } ''
    mkdir -p $out/include
    cat > $out/include/redox_locale_stubs.h << 'STUBS'
    #ifndef _REDOX_LOCALE_STUBS_H
    #define _REDOX_LOCALE_STUBS_H
    #include <stdlib.h>
    #include <stdio.h>
    #include <locale.h>

    /* strto*_l: relibc declares these nowhere — ignore locale, use C versions */
    static inline float strtof_l(const char *n, char **e, locale_t l) { (void)l; return strtof(n, e); }
    static inline double strtod_l(const char *n, char **e, locale_t l) { (void)l; return strtod(n, e); }
    static inline long double strtold_l(const char *n, char **e, locale_t l) { (void)l; return strtold(n, e); }
    static inline long long strtoll_l(const char *n, char **e, int b, locale_t l) { (void)l; return strtoll(n, e, b); }
    static inline unsigned long long strtoull_l(const char *n, char **e, int b, locale_t l) { (void)l; return strtoull(n, e, b); }

    static inline int snprintf_l(char *buf, size_t sz, locale_t l, const char *fmt, ...) {
      (void)l;
      int r;
      __builtin_va_list ap;
      __builtin_va_start(ap, fmt);
      r = vsnprintf(buf, sz, fmt, ap);
      __builtin_va_end(ap);
      return r;
    }
    static inline int sscanf_l(const char *buf, locale_t l, const char *fmt, ...) {
      (void)l;
      int r;
      __builtin_va_list ap;
      __builtin_va_start(ap, fmt);
      r = vsscanf(buf, fmt, ap);
      __builtin_va_end(ap);
      return r;
    }
    static inline int asprintf_l(char **ret, locale_t l, const char *fmt, ...) {
      (void)l;
      int r;
      __builtin_va_list ap;
      __builtin_va_start(ap, fmt);
      r = vasprintf(ret, fmt, ap);
      __builtin_va_end(ap);
      return r;
    }
    #endif /* _REDOX_LOCALE_STUBS_H */
    STUBS

    # locale.h wrapper — includes relibc's locale.h then our stubs
    cat > $out/include/locale.h << 'LOCALE'
    #ifndef _REDOX_LOCALE_WRAPPER_H
    #define _REDOX_LOCALE_WRAPPER_H
    #include_next <locale.h>
    #include <redox_locale_stubs.h>
    #endif
    LOCALE
  '';

  cxxWrapper = pkgs.writeShellScript "redox-cxx" ''
    for arg in "$@"; do
      case "$arg" in
        -c|-S|-E|-M|-MM) exec ${cxx} --target=${redoxTarget} --sysroot=${sysroot} -D__redox__ \
          -nostdlibinc -isystem ${localeStubs}/include \
          -isystem ${redox-libcxx}/include/c++/v1 -isystem ${sysroot}/include \
          -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE "$@" ;;
      esac
    done
    exec ${cxx} --target=${redoxTarget} --sysroot=${sysroot} -D__redox__ \
      -static -nostdlib \
      -nostdlibinc -isystem ${localeStubs}/include \
      -isystem ${redox-libcxx}/include/c++/v1 -isystem ${sysroot}/include \
      -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE \
      ${sysroot}/lib/crt0.o ${sysroot}/lib/crti.o \
      "$@" \
      -L${sysroot}/lib -L${redox-libcxx}/lib -L${stubLibs}/lib \
      -lc++ -lc++abi -lunwind -lc -lpthread -lgcc \
      ${sysroot}/lib/crtn.o \
      -fuse-ld=lld
  '';

  # Pre-fetch ALL artifacts the bootstrap tries to download.
  # The Nix sandbox has no network access, so these must be provided.
  # Date 2025-09-27 comes from the stage0 manifest in the source tarball.
  stage0Date = "2025-09-27";
  stage0Artifacts = {
    rustfmt = pkgs.fetchurl {
      url = "https://static.rust-lang.org/dist/2025-09-27/rustfmt-nightly-x86_64-unknown-linux-gnu.tar.xz";
      hash = "sha256-zZTiC0mFlkRCsIBFTCtii8tDWJjlC8LeVXmcxRzXXxY=";
    };
    rustc = pkgs.fetchurl {
      url = "https://static.rust-lang.org/dist/2025-09-27/rustc-nightly-x86_64-unknown-linux-gnu.tar.xz";
      hash = "sha256-KrF2BXg1+r1V5uI3KwNsJFvkTAcFGYVX7yoW0YfqlFc=";
    };
    rust-std = pkgs.fetchurl {
      url = "https://static.rust-lang.org/dist/2025-09-27/rust-std-nightly-x86_64-unknown-linux-gnu.tar.xz";
      hash = "sha256-Zy7GDtUOu/MLHhrdVnOBPSvRwwbz5BXv07Y20yHIUUs=";
    };
    cargo = pkgs.fetchurl {
      url = "https://static.rust-lang.org/dist/2025-09-27/cargo-nightly-x86_64-unknown-linux-gnu.tar.xz";
      hash = "sha256-5yHeY7rp+iIO+J8HqJ//ZUPVZF48JK93GpbV7i9wqUU=";
    };
  };

  # Fake llvm-config for the cross-compiled LLVM.
  # The Rust bootstrap calls llvm-config to get library/include paths.
  # The real llvm-config is a Redox binary, so we need a host-native wrapper.
  crossLlvmConfig = pkgs.writeShellScript "llvm-config-redox" ''
    # Handle combined flags like: --link-static --libs core support ...
    ARGS="$*"

    case "$ARGS" in
      *--version*)   echo "21.1.2" ;;
      *--prefix*)    echo "${redox-llvm}" ;;
      *--bindir*)    echo "${redox-llvm}/bin" ;;
      *--libdir*)    echo "${redox-llvm}/lib" ;;
      *--includedir*) echo "${redox-llvm}/include" ;;
      *--cxxflags*)  echo "-I${redox-llvm}/include -std=c++17 -fno-exceptions -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
      *--cflags*)    echo "-I${redox-llvm}/include -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
      *--ldflags*)   echo "-L${redox-llvm}/lib" ;;
      *--system-libs*) echo "-L${redox-libcxx}/lib -lc++ -lc++abi -lunwind -lm -lpthread" ;;
      *--shared-mode*) echo "static" ;;
      *--has-rtti*)  echo "NO" ;;
      *--assertion-mode*) echo "OFF" ;;
      *--build-mode*) echo "Release" ;;
      *--targets-built*) echo "X86" ;;
      *--libs*)
        libs=""
        for f in ${redox-llvm}/lib/libLLVM*.a; do
          name=$(basename "$f" .a | sed 's/^lib/-l/')
          libs="$libs $name"
        done
        echo "$libs"
        ;;
      *--components*)
        for f in ${redox-llvm}/lib/libLLVM*.a; do
          basename "$f" .a | sed 's/^libLLVM//' | tr '[:upper:]' '[:lower:]'
        done | tr '\n' ' '
        echo
        ;;
      *)
        echo "llvm-config-redox: unknown: $*" >&2
        exit 1
        ;;
    esac
  '';

in
pkgs.stdenv.mkDerivation {
  pname = "rustc-redox";
  version = "nightly-2025-10-03";

  # Official Rust nightly source tarball — includes vendored deps
  src = pkgs.fetchurl {
    url = "https://static.rust-lang.org/dist/2025-10-03/rustc-nightly-src.tar.xz";
    hash = "sha256-iKRQKhDquTdLzivsaTHfizmzFxEMh6twn67oAMBH5Po=";
  };

  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    rustToolchain
    cmake
    ninja
    python3
    pkg-config
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.lld
    llvmPackages.llvm.dev
    llvmPackages.llvm.lib
    gnumake
    file
    # Host libraries needed for stage 1 linking (via host LLVM)
    libxml2
    zlib
    zstd
    ncurses
    libffi
  ];

  # Disable default unpack — we do it manually to cd into the right dir
  unpackPhase = ''
    tar xf $src
    cd rustc-nightly-src
    export SRCDIR=$(pwd)

    # Pre-populate bootstrap download cache so it doesn't need network.
    # The bootstrap checks build/cache/{date}/ for artifacts before downloading.
    mkdir -p build/cache/${stage0Date}
    cp ${stage0Artifacts.rustfmt} build/cache/${stage0Date}/rustfmt-nightly-x86_64-unknown-linux-gnu.tar.xz
    cp ${stage0Artifacts.rustc} build/cache/${stage0Date}/rustc-nightly-x86_64-unknown-linux-gnu.tar.xz
    cp ${stage0Artifacts.rust-std} build/cache/${stage0Date}/rust-std-nightly-x86_64-unknown-linux-gnu.tar.xz
    cp ${stage0Artifacts.cargo} build/cache/${stage0Date}/cargo-nightly-x86_64-unknown-linux-gnu.tar.xz
    echo "=== Stage 0 cache populated ==="
    ls -la build/cache/${stage0Date}/
  '';

  configurePhase = ''
    runHook preConfigure

    echo "=== Applying Redox patches ==="

    # Patch 1: available_parallelism — SKIPPED
    # The upstream libc crate for Redox doesn't define _SC_NPROCESSORS_ONLN.
    # The Redox fork patches the vendored libc, but we use the upstream tarball.
    # std handles the fallback gracefully (returns Err or defaults to 1).

    # Patch 2: Sysroot fallback to / (commit 7335d7e1)
    python3 << 'PYEOF'
    path = "compiler/rustc_session/src/filesearch.rs"
    with open(path) as f:
        content = f.read()
    content = content.replace(
        '.unwrap_or_else(|| default_from_rustc_driver_dll().expect("Failed finding sysroot"))',
        '.unwrap_or_else(|| default_from_rustc_driver_dll().unwrap_or(PathBuf::from("/")))'
    )
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}")
    PYEOF

    # Patch 3: crt_static_allows_dylibs — REMOVED
    # Upstream already has crt_static_allows_dylibs: true AND dynamic_linking: true.
    # The old patch was BREAKING this by setting it to false, preventing proc-macros.

    # Patch 4: CMAKE_SYSTEM_NAME for Redox (commit 97b598cb)
    python3 << 'PYEOF'
    path = "src/bootstrap/src/core/build_steps/llvm.rs"
    with open(path) as f:
        content = f.read()
    # Add Redox handling before the "none" catch-all
    content = content.replace(
        '} else if target.contains("none") {',
        '} else if target.contains("redox") {\n            cfg.define("CMAKE_SYSTEM_NAME", "UnixPaths");\n        } else if target.contains("none") {'
    )
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}")
    PYEOF

    # Patch 5: cargo-util S_IRWXU type mismatch
    # On Redox, libc::S_IRWXU etc. are i32 (not u32 like Linux).
    # Cargo uses u32::from() which doesn't accept i32.
    python3 << 'PYEOF'
    path = "src/tools/cargo/crates/cargo-util/src/paths.rs"
    with open(path) as f:
        content = f.read()
    content = content.replace(
        'u32::from(libc::S_IRWXU | libc::S_IRWXG | libc::S_IRWXO)',
        '(libc::S_IRWXU | libc::S_IRWXG | libc::S_IRWXO) as u32'
    )
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}")
    PYEOF

    echo "=== Generating config.toml ==="

    # Generate config.toml with proper paths
    python3 << PYEOF
    config = """
    [build]
    build = "x86_64-unknown-linux-gnu"
    host = ["x86_64-unknown-redox"]
    target = ["x86_64-unknown-redox"]
    cargo = "${rustToolchain}/bin/cargo"
    rustc = "${rustToolchain}/bin/rustc"
    extended = true
    tools = ["cargo", "rustdoc"]
    submodules = false
    vendor = true
    docs = false
    verbose = 1
    profiler = false

    [llvm]
    download-ci-llvm = false
    link-shared = false
    static-libstdcpp = false

    [rust]
    codegen-tests = false
    backtrace = false
    lld = false
    llvm-tools = false
    channel = "nightly"
    jemalloc = false
    download-rustc = false

    [target.x86_64-unknown-redox]
    cc = "${ccWrapper}"
    cxx = "${cxxWrapper}"
    ar = "${ar}"
    ranlib = "${ranlib}"
    linker = "${ccWrapper}"
    llvm-config = "${crossLlvmConfig}"
    crt-static = true

    [target.x86_64-unknown-linux-gnu]
    llvm-config = "${hostLlvmDev}/bin/llvm-config"

    [dist]
    src-tarball = false

    [install]
    prefix = "$out"
    sysconfdir = "$out/etc"
    """
    with open("config.toml", "w") as f:
        f.write(config)
    PYEOF

    # Verify config
    echo "=== config.toml ==="
    cat config.toml
    echo "==================="

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Unset cross-compilation variables that confuse the bootstrap
    unset AR AS CC CXX LD LDFLAGS NM OBJCOPY OBJDUMP RANLIB READELF STRIP
    unset CARGO_BUILD_TARGET CARGO_ENCODED_RUSTFLAGS RUSTFLAGS

    # Point bootstrap at our stage 0 tools so it doesn't try to download
    export RUSTFMT="${rustToolchain}/bin/rustfmt"

    # Point openssl-sys at our cross-compiled OpenSSL for the Redox target
    export X86_64_UNKNOWN_REDOX_OPENSSL_DIR="${redox-openssl}"
    export X86_64_UNKNOWN_REDOX_OPENSSL_STATIC=1

    # Build stage 2 (cross-compiled for Redox)
    python3 x.py build --config config.toml -j $NIX_BUILD_CORES 2>&1

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    python3 x.py install --config config.toml 2>&1

    echo "=== Installed files ==="
    find $out -type f -name 'rustc' -o -name 'cargo' -o -name 'rustdoc' | while read f; do
      echo "$f: $(file "$f") — $(du -sh "$f" | cut -f1)"
    done

    # Fix RUNPATH for dynamically linked binaries (rustc, rustdoc).
    # The cross-compilation embeds host Nix store paths in RUNPATH which
    # don't exist on the Redox guest. Replace with $ORIGIN-relative path
    # that works regardless of install location.
    echo "=== Fixing RUNPATH ==="
    for bin in $out/bin/rustc $out/bin/rustdoc; do
      if [ -f "$bin" ] && file "$bin" | grep -q "dynamically linked"; then
        echo "Patching RUNPATH: $bin"
        ${pkgs.patchelf}/bin/patchelf --set-rpath '$ORIGIN/../lib' "$bin"
      fi
    done

    # Also fix RUNPATH on all .so files in lib/
    for so in $out/lib/*.so; do
      if [ -f "$so" ]; then
        echo "Patching RUNPATH: $so"
        ${pkgs.patchelf}/bin/patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
      fi
    done

    # Build stub libstdc++.so.6 with C++ ABI symbols needed by LLVM code
    # The Rust build system adds -lstdc++ to librustc_driver.so NEEDED.
    # We use libc++ (statically linked), so the actual C++ stdlib is present,
    # but __cxa_guard_* symbols for static init are expected via dynamic linking.
    # NOTE: librustc_driver.so has NEEDED: libstdc++.so.6 (from Rust build system).
    # The redox-libstdcxx-shim package provides this as a shared lib from libc++.
    # It must be in LD_LIBRARY_PATH alongside librustc_driver.so.

    runHook postInstall
  '';

  meta = {
    description = "Rust compiler (rustc + cargo) for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/rust";
    license = with lib.licenses; [
      mit
      asl20
    ];
  };
}
