# libc++ — LLVM C++ standard library cross-compiled for Redox OS
#
# Builds libunwind + libc++abi + libc++ as static libraries for x86_64-unknown-redox.
# Required by: LLVM, Clang, LLD, cmake (all written in C++)
#
# Source: Redox fork of LLVM at gitlab.redox-os.org/redox-os/llvm-project
# Branch: redox-2025-10-03 (based on llvmorg-21.1.2)
#
# Uses the unified runtimes build (cmake -S runtimes) with Makefiles
# (Ninja has duplicate target conflicts with libc++abi.a).
#
# Exception support: enabled (cmake and other C++ apps use try/catch).
# Unwinding: LLVM libunwind (pure C, no external deps).
#
# Output: libc++.a + libc++abi.a + libunwind.a + headers

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
    hash = "sha256-6xgLcStJRJGluK8SZvGndacqQp6YKmjoPGk3Zg/mBc0=";
    fetchSubmodules = false;
    sparseCheckout = [
      "libcxx"
      "libcxxabi"
      "libunwind"
      "libc"
      "runtimes"
      "cmake"
      "llvm/cmake"
      "llvm/utils/llvm-lit"
    ];
  };

  # Header with declarations for functions missing from relibc.
  # Force-included in all C++ compilation units.
  wcharCompat = pkgs.writeText "wchar_compat.h" ''
    #ifndef REDOX_WCHAR_COMPAT_H
    #define REDOX_WCHAR_COMPAT_H

    #if defined(__redox__) && defined(__cplusplus)
    #include <stddef.h>
    #include <bits/locale-t.h>
    #include <wctype.h>

    extern "C" {

    /* Wide char functions missing from relibc */
    float wcstof(const wchar_t * __restrict__ ptr, wchar_t ** __restrict__ end);
    long double wcstold(const wchar_t * __restrict__ ptr, wchar_t ** __restrict__ end);

    /* Locale-aware wide char classification (relibc only has C locale) */
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

    /* Locale-aware conversions */
    float strtof_l(const char *, char **, locale_t);
    double strtod_l(const char *, char **, locale_t);
    long double strtold_l(const char *, char **, locale_t);
    long long strtoll_l(const char *, char **, int, locale_t);
    unsigned long long strtoull_l(const char *, char **, int, locale_t);

    /* Locale-aware wide char case conversion */
    wint_t towupper_l(wint_t, locale_t);
    wint_t towlower_l(wint_t, locale_t);

    /* Locale-aware wide string collation */
    int wcscoll_l(const wchar_t *, const wchar_t *, locale_t);
    size_t wcsxfrm_l(wchar_t *, const wchar_t *, size_t, locale_t);

    /* Locale-aware time formatting */
    size_t strftime_l(char *, size_t, const char *, const struct tm *, locale_t);

    /* Locale-aware snprintf/sscanf (used by bsd_locale_fallbacks.h) */
    int snprintf_l(char *, size_t, locale_t, const char *, ...);
    int asprintf_l(char **, locale_t, const char *, ...);
    int sscanf_l(const char *, locale_t, const char *, ...);

    /* POSIX *at functions (stubs for filesystem support) */
    struct timespec;
    int openat(int, const char *, int, ...);
    int unlinkat(int, const char *, int);
    int utimensat(int, const char *, const struct timespec[2], int);

    }
    #endif /* __redox__ && __cplusplus */
    #endif /* REDOX_WCHAR_COMPAT_H */
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
        #include <wctype.h>
        #include <stdlib.h>
        #include <string.h>
        #include <errno.h>
        #include <locale.h>

        extern "C" {

        // Wide char functions missing from relibc
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

        // Locale-aware wide char classification stubs.
        // Redox only has the "C" locale, so _l variants just call the base functions.
        int iswspace_l(wint_t c, locale_t) { return iswspace(c); }
        int iswprint_l(wint_t c, locale_t) { return iswprint(c); }
        int iswcntrl_l(wint_t c, locale_t) { return iswcntrl(c); }
        int iswupper_l(wint_t c, locale_t) { return iswupper(c); }
        int iswlower_l(wint_t c, locale_t) { return iswlower(c); }
        int iswalpha_l(wint_t c, locale_t) { return iswalpha(c); }
        int iswblank_l(wint_t c, locale_t) { return iswblank(c); }
        int iswdigit_l(wint_t c, locale_t) { return iswdigit(c); }
        int iswpunct_l(wint_t c, locale_t) { return iswpunct(c); }
        int iswxdigit_l(wint_t c, locale_t) { return iswxdigit(c); }
        int iswctype_l(wint_t c, wctype_t t, locale_t) { return iswctype(c, t); }

        // Locale-aware string/number conversion stubs
        float strtof_l(const char *s, char **e, locale_t) { return strtof(s, e); }
        double strtod_l(const char *s, char **e, locale_t) { return strtod(s, e); }
        long double strtold_l(const char *s, char **e, locale_t) { return strtold(s, e); }
        long long strtoll_l(const char *s, char **e, int b, locale_t) { return strtoll(s, e, b); }
        unsigned long long strtoull_l(const char *s, char **e, int b, locale_t) { return strtoull(s, e, b); }

        // Locale-aware wide char case conversion stubs
        wint_t towupper_l(wint_t c, locale_t) { return towupper(c); }
        wint_t towlower_l(wint_t c, locale_t) { return towlower(c); }

        // Locale-aware wide string collation stubs
        int wcscoll_l(const wchar_t *a, const wchar_t *b, locale_t) { return wcscoll(a, b); }
        size_t wcsxfrm_l(wchar_t *d, const wchar_t *s, size_t n, locale_t) { return wcsxfrm(d, s, n); }

        // Locale-aware time formatting stub
        size_t strftime_l(char *s, size_t max, const char *fmt, const struct tm *tm, locale_t) {
          return strftime(s, max, fmt, tm);
        }

        // Thread-local storage atexit handler (needed by LLD)
        // In a full libc++abi, this registers destructors for thread_local objects.
        // Stub: Redox doesn't have robust TLS cleanup yet.
        int __cxa_thread_atexit(void (*)(void*), void*, void*) { return 0; }

        // POSIX *at functions missing from relibc (needed by libc++ filesystem)
        #include <fcntl.h>
        #include <sys/stat.h>
        int openat(int dirfd, const char *path, int flags, ...) {
          (void)dirfd;
          // Ignore dirfd — Redox doesn't support *at functions, fall back to open()
          va_list ap;
          va_start(ap, flags);
          mode_t mode = 0;
          if (flags & O_CREAT) mode = va_arg(ap, int);
          va_end(ap);
          return open(path, flags, mode);
        }
        int unlinkat(int dirfd, const char *path, int flags) {
          (void)dirfd; (void)flags;
          return unlink(path);
        }
        int utimensat(int dirfd, const char *path, const struct timespec ts[2], int flags) {
          (void)dirfd; (void)path; (void)ts; (void)flags;
          // No-op: Redox doesn't support utimensat
          return 0;
        }

        // Locale-aware printf/scanf stubs (ignore locale, use C locale)
        #include <stdarg.h>
        int snprintf_l(char *buf, size_t n, locale_t, const char *fmt, ...) {
          va_list ap;
          va_start(ap, fmt);
          int r = vsnprintf(buf, n, fmt, ap);
          va_end(ap);
          return r;
        }
        int asprintf_l(char **ret, locale_t, const char *fmt, ...) {
          va_list ap;
          va_start(ap, fmt);
          int r = vasprintf(ret, fmt, ap);
          va_end(ap);
          return r;
        }
        int sscanf_l(const char *s, locale_t, const char *fmt, ...) {
          va_list ap;
          va_start(ap, fmt);
          int r = vsscanf(s, fmt, ap);
          va_end(ap);
          return r;
        }

        }
        #endif
  STUBS
        sed -i '/set(LIBCXX_SOURCES/a\  wchar_stubs_redox.cpp' libcxx/src/CMakeLists.txt
        echo "Patched libcxx: added wcstof/wcstold + locale stubs for Redox"

        # libunwind needs link.h for dl_iterate_phdr (ELF program header iteration).
        # relibc doesn't provide it. Create a stub with a working implementation
        # for static binaries (reports the main executable's headers via __ehdr_start).
        chmod -R u+w libunwind/
        mkdir -p "$SRCDIR/redox-compat/include"

        cat > "$SRCDIR/redox-compat/include/link.h" << 'LINKH'
        #ifndef _LINK_H
        #define _LINK_H

        #include <stddef.h>
        #include <stdint.h>
        #include <elf.h>

        /* ElfW macro (maps to 64-bit ELF types on x86_64) */
        #ifndef ElfW
        #define ElfW(type) Elf64_##type
        #endif

        #ifdef __cplusplus
        extern "C" {
        #endif

        struct dl_phdr_info {
            uint64_t dlpi_addr;
            const char *dlpi_name;
            const struct Elf64_Phdr *dlpi_phdr;
            uint16_t dlpi_phnum;
        };

        int dl_iterate_phdr(int (*callback)(struct dl_phdr_info *, size_t, void *), void *data);

        #ifdef __cplusplus
        }
        #endif
        #endif /* _LINK_H */
  LINKH

        # dl_iterate_phdr for static Redox binaries.
        # Uses the linker-defined __ehdr_start symbol to find program headers.
        cat > libunwind/src/dl_iterate_phdr_redox.c << 'DLSTUB'
        #ifdef __redox__
        #include <stddef.h>
        #include <stdint.h>
        #include <elf.h>

        struct dl_phdr_info {
            uint64_t dlpi_addr;
            const char *dlpi_name;
            const struct Elf64_Phdr *dlpi_phdr;
            uint16_t dlpi_phnum;
        };

        /* Linker-defined symbol at the start of the ELF image in memory. */
        extern const struct Elf64_Ehdr __ehdr_start __attribute__((weak, visibility("hidden")));

        int dl_iterate_phdr(int (*callback)(struct dl_phdr_info *, size_t, void *), void *data) {
            if (&__ehdr_start == 0) return 0;
            struct dl_phdr_info info;
            info.dlpi_addr = 0;
            info.dlpi_name = "";
            info.dlpi_phdr = (const struct Elf64_Phdr *)((const char *)&__ehdr_start + __ehdr_start.e_phoff);
            info.dlpi_phnum = __ehdr_start.e_phnum;
            return callback(&info, sizeof(info), data);
        }
        #endif
  DLSTUB
        # Add to libunwind's CMakeLists.txt source list
        sed -i '/set(LIBUNWIND_SOURCES/a\  dl_iterate_phdr_redox.c' libunwind/src/CMakeLists.txt
        echo "Patched libunwind: added link.h stub + dl_iterate_phdr for Redox"

        # relibc's mbstate_t is an empty struct; = {0} is invalid in C++
        sed -i 's/mbstate_t mb *= {0}/mbstate_t mb = {}/g' \
          libcxx/src/locale.cpp
        echo "Patched libcxx: fixed mbstate_t initializers for relibc"

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
          "-DCMAKE_C_FLAGS=--target=${redoxTarget} --sysroot=${sysroot} -D__redox__ -D_LIBUNWIND_USE_DL_ITERATE_PHDR=1 -fPIC -I$SRCDIR/redox-compat/include -I${sysroot}/include -include ${wcharCompat}" \
          "-DCMAKE_CXX_FLAGS=--target=${redoxTarget} --sysroot=${sysroot} -D__redox__ -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBUNWIND_USE_DL_ITERATE_PHDR=1 -fPIC -I$SRCDIR/redox-compat/include -I${sysroot}/include -include ${wcharCompat} -I$SRCDIR/libc -I$SRCDIR/libc-stubs" \
          -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
          \
          -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
          \
          -DLIBCXX_ENABLE_SHARED=OFF \
          -DLIBCXX_ENABLE_STATIC=ON \
          -DLIBCXX_ENABLE_EXCEPTIONS=ON \
          -DLIBCXX_ENABLE_RTTI=ON \
          -DLIBCXX_ENABLE_THREADS=ON \
          -DLIBCXX_HAS_PTHREAD_API=ON \
          -DLIBCXX_ENABLE_LOCALIZATION=ON \
          -DLIBCXX_ENABLE_WIDE_CHARACTERS=ON \
          -DLIBCXX_ENABLE_UNICODE=OFF \
          -DLIBCXX_ENABLE_RANDOM_DEVICE=ON \
          -DLIBCXX_ENABLE_FILESYSTEM=ON \
          -DLIBCXX_CXX_ABI=libcxxabi \
          -DLIBCXX_USE_COMPILER_RT=OFF \
          -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
          -DLIBCXX_INCLUDE_TESTS=OFF \
          \
          -DLIBCXXABI_ENABLE_SHARED=OFF \
          -DLIBCXXABI_ENABLE_STATIC=ON \
          -DLIBCXXABI_ENABLE_EXCEPTIONS=ON \
          -DLIBCXXABI_USE_COMPILER_RT=OFF \
          -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
          -DLIBCXXABI_ENABLE_THREADS=ON \
          -DLIBCXXABI_HAS_PTHREAD_API=ON \
          \
          -DLIBUNWIND_ENABLE_SHARED=OFF \
          -DLIBUNWIND_ENABLE_STATIC=ON \
          -DLIBUNWIND_ENABLE_THREADS=ON \
          -DLIBUNWIND_USE_COMPILER_RT=OFF \
          -DLIBUNWIND_IS_BAREMETAL=OFF \
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
