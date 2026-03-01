# LLVM + Clang + LLD — C/C++ compiler toolchain for Redox OS
#
# Cross-compiles the complete LLVM toolchain for x86_64-unknown-redox.
# Uses the Redox fork of LLVM (7 patches on top of llvmorg-21.1.2).
#
# Build approach:
#   - Monolithic cmake build: LLVM + Clang + LLD in one invocation
#   - Static libraries (LLVM_BUILD_LLVM_DYLIB=Off for simplicity)
#   - Native tablegen built for host during cross-compilation
#   - Links against libc++ (from libcxx-redox) for C++ runtime
#   - X86 target only
#
# Source: gitlab.redox-os.org/redox-os/llvm-project branch redox-2025-10-03
#
# Output: clang, clang++, lld, ld.lld, llvm-ar, llvm-nm, llvm-objcopy, llvm-strip

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-libcxx,
  redox-zstd ? null,
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
  ld = "${pkgs.llvmPackages.lld}/bin/ld.lld";

  src = pkgs.fetchgit {
    url = "https://gitlab.redox-os.org/redox-os/llvm-project.git";
    rev = "250d0b022e5ae323f57659a1063bb40728f3629c";
    hash = "sha256-hTjPpIoG2SvUqlnWAuDqFbINLlTvMTfmN6xqPygoz1g=";
    fetchSubmodules = false;
    # Full checkout needed for LLVM + Clang + LLD build
    sparseCheckout = [
      "llvm"
      "clang"
      "lld"
      "cmake"
      "third-party"
    ];
  };

  # CMake toolchain file for native (host) tablegen builds
  nativeCmake = pkgs.writeText "native.cmake" ''
    set(CMAKE_C_COMPILER "cc")
    set(CMAKE_CXX_COMPILER "c++")
  '';

  # C++ flags for cross-compilation with libc++
  #
  # Include path order is critical:
  # 1. libc++ C++ headers (vector, string, etc.)
  # 2. libc++ C wrapper headers (stdio.h, errno.h — use #include_next)
  # 3. relibc C headers (via --sysroot)
  #
  # -nostdlibinc removes ALL standard library include paths (both C and C++),
  # then we add them back in the correct order with -isystem.
  cxxFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "-D__redox__"
    "-fPIC"
    "-nostdlibinc"
    "-isystem"
    "${redox-libcxx}/include/c++/v1"
    "-isystem"
    "${sysroot}/include"
    "-include"
    "${wcharCompat}"
    "--std=gnu++17"
  ];

  # Header with declarations for wcstof/wcstold missing from relibc
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

  cFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-D__redox__"
    "-fPIC"
  ];

  # Linker flags: static binary linked against libc++ and relibc
  ldFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-fuse-ld=lld"
    "-static"
    "-nostdlib"
    "-L${redox-libcxx}/lib"
    "-L${sysroot}/lib"
    "${sysroot}/lib/crt0.o"
    "${sysroot}/lib/crti.o"
    "-lc++"
    "-lc++abi"
    "-lc"
    "-lpthread"
    "${sysroot}/lib/crtn.o"
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "llvm-redox";
  version = "21.1.2";

  inherit src;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    cmake
    ninja
    python3
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.lld
    # Host tools needed for native tablegen
    gcc
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p build && cd build

    cmake ../llvm \
      -GNinja \
      -DCMAKE_BUILD_TYPE=MinSizeRel \
      -DCMAKE_INSTALL_PREFIX=$out \
      \
      -DCMAKE_SYSTEM_NAME=Generic \
      -DCMAKE_SYSTEM_PROCESSOR=${targetArch} \
      -DCMAKE_C_COMPILER=${cc} \
      -DCMAKE_CXX_COMPILER=${cxx} \
      -DCMAKE_AR=${ar} \
      -DCMAKE_RANLIB=${ranlib} \
      -DCMAKE_NM=${nm} \
      -DCMAKE_LINKER=${ld} \
      -DCMAKE_C_COMPILER_TARGET=${redoxTarget} \
      -DCMAKE_CXX_COMPILER_TARGET=${redoxTarget} \
      -DCMAKE_SYSROOT=${sysroot} \
      "-DCMAKE_C_FLAGS=${cFlags}" \
      "-DCMAKE_CXX_FLAGS=${cxxFlags}" \
      "-DCMAKE_EXE_LINKER_FLAGS=${ldFlags}" \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      \
      -DLLVM_ENABLE_PROJECTS="clang;lld" \
      -DLLVM_TARGETS_TO_BUILD="X86" \
      -DLLVM_DEFAULT_TARGET_TRIPLE="${redoxTarget}" \
      -DLLVM_TARGET_ARCH=${targetArch} \
      \
      -DLLVM_BUILD_LLVM_DYLIB=OFF \
      -DBUILD_SHARED_LIBS=OFF \
      -DLLVM_BUILD_STATIC=ON \
      -DLLVM_ENABLE_RTTI=ON \
      -DLLVM_ENABLE_THREADS=ON \
      \
      -DLLVM_ENABLE_LIBXML2=OFF \
      -DLLVM_ENABLE_ZLIB=OFF \
      -DLLVM_ENABLE_ZSTD=OFF \
      -DLLVM_ENABLE_TERMINFO=OFF \
      -DLLVM_ENABLE_LIBEDIT=OFF \
      \
      -DLLVM_BUILD_EXAMPLES=OFF \
      -DLLVM_BUILD_TESTS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      \
      -DLLVM_OPTIMIZED_TABLEGEN=ON \
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_TOOLCHAIN_FILE=${nativeCmake}" \
      \
      -DLLVM_ENABLE_LIBCXX=ON \
      -DLLVM_LIBSTDCXX_MIN=ON \
      -DLLVM_LIBSTDCXX_SOFT_ERROR=ON \
      -DHAVE_CXX_ATOMICS_WITHOUT_LIB=ON \
      -DHAVE_CXX_ATOMICS64_WITHOUT_LIB=ON \
      -DLLVM_TOOLS_INSTALL_DIR=bin \
      -DLLVM_UTILS_INSTALL_DIR=bin \
      -DUNIX=1 \
      -Wno-dev

    cd ..
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Build with reduced parallelism to avoid OOM (LLVM is memory-hungry)
    ninja -C build -j $(( NIX_BUILD_CORES > 8 ? 8 : NIX_BUILD_CORES ))
    runHook postBuild
  '';

  installPhase = ''
    ninja -C build install

    # Create convenience symlinks
    cd $out/bin
    ln -sf clang clang++
    ln -sf lld ld.lld 2>/dev/null || true

    echo "=== Installed binaries ==="
    ls -la $out/bin/ | head -20
    echo "=== Binary sizes ==="
    du -sh $out/bin/clang $out/bin/lld $out/bin/llvm-ar 2>/dev/null || true
    echo "=== Total size ==="
    du -sh $out/
  '';

  meta = {
    description = "LLVM + Clang + LLD compiler toolchain for Redox OS";
    license = lib.licenses.asl20;
  };
}
