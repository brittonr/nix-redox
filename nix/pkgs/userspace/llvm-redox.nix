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
  stubLibs,
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
  # Compat header force-included in all C++ files for LLVM build.
  # The locale _l stubs are already compiled into libc++.a — we just need
  # declarations so LLVM's headers can see them, plus _LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE
  # so libc++ uses its own ctype masks instead of glibc's _IS* constants.
  wcharCompat = pkgs.writeText "wchar_compat.h" ''
    #ifndef REDOX_WCHAR_COMPAT_H
    #define REDOX_WCHAR_COMPAT_H

    #if defined(__redox__)
    #ifndef _LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE
    #define _LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE
    #endif
    #endif

    #if defined(__redox__) && defined(__cplusplus)
    #include <bits/locale-t.h>
    #include <wctype.h>
    #include <time.h>
    extern "C" {
    float wcstof(const wchar_t * __restrict__ ptr, wchar_t ** __restrict__ end);
    long double wcstold(const wchar_t * __restrict__ ptr, wchar_t ** __restrict__ end);
    int iswspace_l(wint_t, locale_t);
    int iswprint_l(wint_t, locale_t);
    int iswcntrl_l(wint_t, locale_t);
    int iswupper_l(wint_t, locale_t);
    int iswlower_l(wint_t, locale_t);
    int iswalpha_l(wint_t, locale_t);
    int iswblank_l(wint_t, locale_t);
    int iswdigit_l(wint_t, locale_t);
    int iswpunct_l(wint_t, locale_t);
    int iswxdigit_l(wint_t, locale_t);
    int iswctype_l(wint_t, wctype_t, locale_t);
    wint_t towupper_l(wint_t, locale_t);
    wint_t towlower_l(wint_t, locale_t);
    float strtof_l(const char *, char **, locale_t);
    double strtod_l(const char *, char **, locale_t);
    long double strtold_l(const char *, char **, locale_t);
    long long strtoll_l(const char *, char **, int, locale_t);
    unsigned long long strtoull_l(const char *, char **, int, locale_t);
    int wcscoll_l(const wchar_t *, const wchar_t *, locale_t);
    size_t wcsxfrm_l(wchar_t *, const wchar_t *, size_t, locale_t);
    size_t strftime_l(char *, size_t, const char *, const struct tm *, locale_t);
    int snprintf_l(char *, size_t, locale_t, const char *, ...);
    int asprintf_l(char **, locale_t, const char *, ...);
    int sscanf_l(const char *, locale_t, const char *, ...);
    struct timespec;
    int openat(int, const char *, int, ...);
    int unlinkat(int, const char *, int);
    int utimensat(int, const char *, const struct timespec[2], int);
    }
    #endif
    #endif
  '';

  cFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-D__redox__"
    "-fPIC"
    "-nostdlibinc"
    "-isystem"
    "${sysroot}/include"
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
    "-L${stubLibs}/lib"
    "${sysroot}/lib/crt0.o"
    "${sysroot}/lib/crti.o"
    "-lc++"
    "-lc++abi"
    "-lc"
    "-lpthread"
    "-lgcc"
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

    # Disable MachO/COFF/MinGW linkers — we only need ELF+Wasm for Redox.
    # MachO needs macOS headers (mach-o/compact_unwind_encoding.h),
    # COFF needs Windows headers.
    chmod -R u+w lld/

    # Remove MachO and COFF subdirectories from build
    sed -i '/add_subdirectory(MachO)/d; /add_subdirectory(COFF)/d' lld/CMakeLists.txt

    # Rewrite lld driver CMakeLists.txt to only link ELF+Wasm
    cat > lld/tools/lld/CMakeLists.txt << 'LLDCMAKE'
    set(LLVM_LINK_COMPONENTS Support TargetParser)
    add_lld_tool(lld lld.cpp SUPPORT_PLUGINS GENERATE_DRIVER)
    export_executable_symbols_for_plugins(lld)
    function(lld_target_link_libraries target type)
      if (TARGET obj.''${target})
        target_link_libraries(obj.''${target} ''${ARGN})
      endif()
      get_property(LLVM_DRIVER_TOOLS GLOBAL PROPERTY LLVM_DRIVER_TOOLS)
      if(LLVM_TOOL_LLVM_DRIVER_BUILD AND ''${target} IN_LIST LLVM_DRIVER_TOOLS)
        set(target llvm-driver)
      endif()
      target_link_libraries(''${target} ''${type} ''${ARGN})
    endfunction()
    lld_target_link_libraries(lld PRIVATE lldCommon lldELF lldWasm)
    set(LLD_SYMLINKS_TO_CREATE ld.lld wasm-ld)
    foreach(link ''${LLD_SYMLINKS_TO_CREATE})
      add_lld_symlink(''${link} lld)
    endforeach()
  LLDCMAKE

    # Remove driver registrations for disabled linker flavors
    sed -i '/LLD_HAS_DRIVER(coff)/d; /LLD_HAS_DRIVER(macho)/d; /LLD_HAS_DRIVER(mingw)/d' lld/tools/lld/lld.cpp

    # Rewrite LLD_ALL_DRIVERS to only include ELF+Wasm
    chmod -R u+w lld/include/
    sed -i '/^#define LLD_ALL_DRIVERS/,/^  }$/c\
    #define LLD_ALL_DRIVERS \\\
      { {lld::Gnu, \&lld::elf::link}, {lld::Wasm, \&lld::wasm::link} }' \
      lld/include/lld/Common/Driver.h

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
      -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
      -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
      -DCLANG_TOOL_CLANG_REPL_BUILD=OFF \
      \
      -DLLVM_OPTIMIZED_TABLEGEN=ON \
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_TOOLCHAIN_FILE=${nativeCmake}" \
      \
      -DLLVM_ENABLE_LIBCXX=ON \
      -DHAVE_CXX_ATOMICS_WITHOUT_LIB=ON \
      -DHAVE_CXX_ATOMICS64_WITHOUT_LIB=ON \
      -DLLVM_TOOLS_INSTALL_DIR=bin \
      -DLLVM_UTILS_INSTALL_DIR=bin \
      -DUNIX=1 \
      \
      -DHAVE_SYSEXITS_H=1 \
      -DHAVE_PTHREAD_H=1 \
      -DHAVE_SYS_MMAN_H=1 \
      -DHAVE_UNISTD_H=1 \
      -DHAVE_SYS_IOCTL_H=1 \
      -DHAVE_DLFCN_H=1 \
      -DHAVE_FENV_H=1 \
      \
      -DHAVE_GETPAGESIZE=1 \
      -DHAVE_SYSCONF=1 \
      -DHAVE_GETRUSAGE=1 \
      -DHAVE_ISATTY=1 \
      -DHAVE_FUTIMENS=1 \
      -DHAVE_SETENV=1 \
      -DHAVE_PREAD=1 \
      -DHAVE_STRERROR_R=1 \
      -DHAVE_SIGALTSTACK=1 \
      -DHAVE_SBRK=1 \
      -DHAVE_GETAUXVAL=1 \
      -DHAVE_STRUCT_STAT_ST_MTIM_TV_NSEC=1 \
      \
      -DHAVE_FE_ALL_EXCEPT=1 \
      -DHAVE_FE_INEXACT=1 \
      -DLLVM_ENABLE_THREADS=ON \
      -DHAVE_PTHREAD_MUTEX_LOCK=1 \
      -DHAVE_PTHREAD_RWLOCK_INIT=1 \
      -DLLVM_HAS_ATOMICS=1 \
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

    # Strip to only the binaries needed for self-hosting on Redox.
    # The full install has 103 binaries (1.3 GB); we only need ~8 (200 MB).
    cd $out/bin
    keepBins=(
      clang-21    # C/C++ compiler (real binary)
      lld         # linker (real binary)
      llvm-ar     # archive tool
      llvm-nm     # symbol lister
      llvm-objcopy  # binary manipulation
      llvm-objdump  # disassembler
      llvm-readobj  # ELF reader
    )
    for f in *; do
      keep=0
      for k in "''${keepBins[@]}"; do
        [ "$f" = "$k" ] && keep=1 && break
      done
      # Also keep symlinks that point to kept binaries
      if [ -L "$f" ]; then
        target=$(readlink "$f")
        for k in "''${keepBins[@]}"; do
          [ "$target" = "$k" ] && keep=1 && break
        done
      fi
      [ "$keep" = "0" ] && rm -f "$f"
    done

    # Recreate essential symlinks
    ln -sf clang-21 clang
    ln -sf clang-21 clang++
    ln -sf lld ld.lld
    ln -sf llvm-objcopy llvm-strip
    ln -sf llvm-readobj llvm-readelf

    echo "=== Installed binaries ==="
    ls -la $out/bin/
    echo "=== Total size ==="
    du -sh $out/
  '';

  meta = {
    description = "LLVM + Clang + LLD compiler toolchain for Redox OS";
    license = lib.licenses.asl20;
  };
}
