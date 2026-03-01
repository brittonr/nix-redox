# libc++ — LLVM C++ standard library cross-compiled for Redox OS
#
# Builds libc++abi + libc++ as static libraries for x86_64-unknown-redox.
# Required by: LLVM, Clang, LLD (all written in C++)
#
# Source: Redox fork of LLVM at gitlab.redox-os.org/redox-os/llvm-project
# Branch: redox-2025-10-03 (based on llvmorg-21.1.2)
#
# Uses the unified runtimes build (cmake -S runtimes) with Makefiles
# (Ninja has duplicate target conflicts with libc++abi.a).
#
# Output: libc++.a + libc++abi.a + headers

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  ...
}:

let
  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  sysroot = "${relibc}/${redoxTarget}";

  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  cxx = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang++";
  ar = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
  ranlib = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib";
  nm = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-nm";

  src = pkgs.fetchgit {
    url = "https://gitlab.redox-os.org/redox-os/llvm-project.git";
    rev = "250d0b022e5ae323f57659a1063bb40728f3629c";
    hash = "sha256-XljG7J4ZdU5j7W8VGBtPfXvEgJDPrmRbbLKjvTcXnfk=";
    fetchSubmodules = false;
    sparseCheckout = [
      "libcxx"
      "libcxxabi"
      "libc"
      "runtimes"
      "cmake"
      "llvm/cmake"
      "llvm/utils/llvm-lit"
    ];
  };

  # Header with declarations for wcstof/wcstold missing from relibc.
  # Only included in C++ mode (where wchar_t is a builtin type).
  wcharCompat = pkgs.writeText "wchar_compat.h" ''
    #ifndef REDOX_WCHAR_COMPAT_H
    #define REDOX_WCHAR_COMPAT_H
    #if defined(__redox__) && defined(__cplusplus)
    extern "C" {
    float wcstof(const wchar_t * __restrict__ ptr, wchar_t ** __restrict__ end);
    long double wcstold(const wchar_t * __restrict__ ptr, wchar_t ** __restrict__ end);
    }
    #endif
    #endif
  '';

in
pkgs.stdenv.mkDerivation {
  pname = "libcxx-redox";
  version = "21.1.2";

  inherit src;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    cmake
    python3
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.lld
    gnumake
  ];

  configurePhase = ''
        runHook preConfigure

        SRCDIR="$(pwd)"

        # relibc's <wchar.h> is missing wcstof and wcstold declarations.
        # libc++'s <cwchar> uses _LIBCPP_USING_IF_EXISTS which marks them
        # "unresolved" → hard error when string.cpp calls them.
        # Fix: force-include a compat header with the missing declarations,
        # and add stub implementations to the libc++ build.
        chmod -R u+w libcxx/

        # Create stub implementations compiled into libc++
        cat > libcxx/src/wchar_stubs_redox.cpp << 'STUBS'
        #ifdef __redox__
        #include <wchar.h>
        #include <errno.h>
        extern "C" {
        float wcstof(const wchar_t * __restrict__ ptr, wchar_t ** __restrict__ end) {
          if (end) *end = (wchar_t*)ptr;
          errno = ENOSYS;
          return 0;
        }
        long double wcstold(const wchar_t * __restrict__ ptr, wchar_t ** __restrict__ end) {
          if (end) *end = (wchar_t*)ptr;
          errno = ENOSYS;
          return 0;
        }
        }
        #endif
    STUBS
        sed -i '/set(LIBCXX_SOURCES/a\  wchar_stubs_redox.cpp' libcxx/src/CMakeLists.txt
        echo "Patched libcxx: added wcstof/wcstold stubs for Redox"

        # LLVM libc's internal headers reference generated headers (hdr/*.h).
        # Create stubs that redirect to the real system headers.
        mkdir -p "$SRCDIR/libc-stubs/hdr/types"
        cat > "$SRCDIR/libc-stubs/hdr/limits_macros.h" << 'EOF'
        #ifndef LLVM_LIBC_HDR_LIMITS_MACROS_H
        #define LLVM_LIBC_HDR_LIMITS_MACROS_H
        #include <limits.h>
        #endif
    EOF
        cat > "$SRCDIR/libc-stubs/hdr/types/float128.h" << 'EOF'
        #ifndef LLVM_LIBC_HDR_TYPES_FLOAT128_H
        #define LLVM_LIBC_HDR_TYPES_FLOAT128_H
        #endif
    EOF
        cat > "$SRCDIR/libc-stubs/hdr/fenv_macros.h" << 'EOF'
        #ifndef LLVM_LIBC_HDR_FENV_MACROS_H
        #define LLVM_LIBC_HDR_FENV_MACROS_H
        #include <fenv.h>
        #endif
    EOF
        cat > "$SRCDIR/libc-stubs/hdr/math_macros.h" << 'EOF'
        #ifndef LLVM_LIBC_HDR_MATH_MACROS_H
        #define LLVM_LIBC_HDR_MATH_MACROS_H
        #include <math.h>
        #endif
    EOF

        mkdir -p build && cd build

        cmake "$SRCDIR/runtimes" \
          -G"Unix Makefiles" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX=$out \
          \
          -DCMAKE_SYSTEM_NAME=Generic \
          -DCMAKE_SYSTEM_PROCESSOR=${targetArch} \
          -DCMAKE_C_COMPILER=${cc} \
          -DCMAKE_CXX_COMPILER=${cxx} \
          -DCMAKE_AR=${ar} \
          -DCMAKE_RANLIB=${ranlib} \
          -DCMAKE_NM=${nm} \
          -DCMAKE_C_COMPILER_TARGET=${redoxTarget} \
          -DCMAKE_CXX_COMPILER_TARGET=${redoxTarget} \
          -DCMAKE_SYSROOT=${sysroot} \
          "-DCMAKE_C_FLAGS=--target=${redoxTarget} --sysroot=${sysroot} -D__redox__ -fPIC -I${sysroot}/include -include ${wcharCompat}" \
          "-DCMAKE_CXX_FLAGS=--target=${redoxTarget} --sysroot=${sysroot} -D__redox__ -fPIC -I${sysroot}/include -include ${wcharCompat} -I$SRCDIR/libc -I$SRCDIR/libc-stubs" \
          -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
          \
          -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
          \
          -DLIBCXX_ENABLE_SHARED=OFF \
          -DLIBCXX_ENABLE_STATIC=ON \
          -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
          -DLIBCXX_ENABLE_RTTI=ON \
          -DLIBCXX_ENABLE_THREADS=ON \
          -DLIBCXX_HAS_PTHREAD_API=ON \
          -DLIBCXX_ENABLE_LOCALIZATION=OFF \
          -DLIBCXX_ENABLE_WIDE_CHARACTERS=ON \
          -DLIBCXX_ENABLE_UNICODE=OFF \
          -DLIBCXX_ENABLE_RANDOM_DEVICE=OFF \
          -DLIBCXX_ENABLE_FILESYSTEM=OFF \
          -DLIBCXX_CXX_ABI=libcxxabi \
          -DLIBCXX_USE_COMPILER_RT=OFF \
          -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
          -DLIBCXX_INCLUDE_TESTS=OFF \
          \
          -DLIBCXXABI_ENABLE_SHARED=OFF \
          -DLIBCXXABI_ENABLE_STATIC=ON \
          -DLIBCXXABI_ENABLE_EXCEPTIONS=OFF \
          -DLIBCXXABI_USE_COMPILER_RT=OFF \
          -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
          -DLIBCXXABI_ENABLE_THREADS=ON \
          -DLIBCXXABI_HAS_PTHREAD_API=ON \
          \
          -Wno-dev

        # Patch __config_site to enable features that relibc supports
        # but cmake cross-compilation detection missed
        CONFIG_SITE="$(find . -name '__config_site' | head -1)"
        if [ -n "$CONFIG_SITE" ]; then
          echo "Patching $CONFIG_SITE for Redox OS..."
          cat >> "$CONFIG_SITE" << 'REDOX_FIXES'

    // Redox OS (relibc) has clock_gettime with CLOCK_MONOTONIC
    #ifndef _LIBCPP_HAS_CLOCK_GETTIME
    #define _LIBCPP_HAS_CLOCK_GETTIME
    #endif
    REDOX_FIXES
        fi

        cd "$SRCDIR"
        runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -C build -j $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    make -C build install

    echo "=== Static libraries ==="
    find $out -name '*.a' | sort
    echo "=== Library sizes ==="
    du -sh $out/lib/*.a 2>/dev/null || echo "no libs"
  '';

  meta = {
    description = "LLVM libc++ (C++ standard library) for Redox OS";
    license = lib.licenses.asl20;
  };
}
