# cmake — cross-compiled build system for Redox OS
#
# CMake bootstraps itself: it has a ./bootstrap script that builds a
# minimal cmake, then uses that to build the full cmake.
#
# For cross-compilation, we:
# 1. Build a native cmake on the host (already in nixpkgs)
# 2. Use it to cross-compile cmake for Redox
#
# We use cmake's bundled third-party libraries (curl, zlib, etc.) rather
# than system versions to minimize cross-compilation dependencies.
# The bundled versions are well-tested and avoid pkg-config issues.

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  stubLibs,
  redox-zlib,
  redox-zstd,
  redox-openssl,
  redox-expat,
  redox-bzip2,
  redox-libcxx,
  ...
}:

let
  mkCLibrary = import ./mk-c-library.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
  };

  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  sysroot = "${relibc}/${redoxTarget}";

  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  cxx = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang++";
  ar = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
  ranlib = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib";
  ld = "${pkgs.llvmPackages.lld}/bin/ld.lld";
  nm = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-nm";
  strip = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-strip";

  baseCFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-D__redox__"
    "-U_FORTIFY_SOURCE"
    "-D_FORTIFY_SOURCE=0"
    "-I${sysroot}/include"
    "-fPIC"
    "-D_GNU_SOURCE"
  ];

  deps = [
    redox-zlib
    redox-zstd
    redox-openssl
    redox-expat
    redox-bzip2
  ];

  depCFlags = lib.concatMapStringsSep " " (d: "-I${d}/include") deps;
  depLdFlags = lib.concatMapStringsSep " " (d: "-L${d}/lib") deps;

  # Stub headers for missing POSIX APIs in relibc.
  # libuv needs sys/statfs.h; we provide a no-op stub.
  # Stub headers for Linux-specific APIs that relibc doesn't implement.
  # libuv (bundled in cmake) expects these when CMAKE_SYSTEM_NAME=Linux.
  sysCompat = pkgs.runCommand "redox-sys-compat" { } ''
    mkdir -p $out/include/sys $out/include/linux

    # statfs: filesystem stats (libuv fs.c)
    cat > $out/include/sys/statfs.h << 'EOF'
    #ifndef _SYS_STATFS_H
    #define _SYS_STATFS_H
    #include <sys/types.h>
    struct statfs { unsigned long f_type, f_bsize; unsigned long long f_blocks, f_bfree, f_bavail, f_files, f_ffree; unsigned long f_namelen, f_frsize, f_spare[5]; };
    static inline int statfs(const char *p, struct statfs *b) { (void)p; (void)b; return -1; }
    static inline int fstatfs(int fd, struct statfs *b) { (void)fd; (void)b; return -1; }
    #endif
    EOF

    # syscall: direct syscall interface (libuv linux-syscalls.c)
    cat > $out/include/sys/syscall.h << 'EOF'
    #ifndef _SYS_SYSCALL_H
    #define _SYS_SYSCALL_H
    #define SYS_dup3 292
    #define SYS_pipe2 293
    #define SYS_getrandom 318
    #define SYS_statx 332
    #define SYS_io_uring_setup 425
    #define SYS_io_uring_enter 426
    #define SYS_io_uring_register 427
    static inline long syscall(long n, ...) { (void)n; return -1; }
    #endif
    EOF

    # prctl: process control (libuv linux-core.c)
    cat > $out/include/sys/prctl.h << 'EOF'
    #ifndef _SYS_PRCTL_H
    #define _SYS_PRCTL_H
    #define PR_SET_NAME 15
    static inline int prctl(int o, ...) { (void)o; return -1; }
    #endif
    EOF

    # inotify: file watch (libuv linux-inotify.c)
    cat > $out/include/sys/inotify.h << 'EOF'
    #ifndef _SYS_INOTIFY_H
    #define _SYS_INOTIFY_H
    #define IN_ATTRIB 4
    #define IN_CLOSE_WRITE 8
    #define IN_CREATE 256
    #define IN_DELETE 512
    #define IN_DELETE_SELF 1024
    #define IN_MODIFY 2
    #define IN_MOVE_SELF 2048
    #define IN_MOVED_FROM 64
    #define IN_MOVED_TO 128
    static inline int inotify_init1(int f) { (void)f; return -1; }
    static inline int inotify_add_watch(int fd, const char *p, unsigned m) { (void)fd; (void)p; (void)m; return -1; }
    static inline int inotify_rm_watch(int fd, int wd) { (void)fd; (void)wd; return -1; }
    #endif
    EOF

    # epoll: I/O event notification (libuv linux-core.c)
    cat > $out/include/sys/epoll.h << 'EOF'
    #ifndef _SYS_EPOLL_H
    #define _SYS_EPOLL_H
    #include <stdint.h>
    #define EPOLLIN 1
    #define EPOLLOUT 4
    #define EPOLLERR 8
    #define EPOLLHUP 16
    #define EPOLLRDHUP 8192
    #define EPOLLONESHOT (1<<30)
    #define EPOLLET (1<<31)
    #define EPOLL_CTL_ADD 1
    #define EPOLL_CTL_DEL 2
    #define EPOLL_CTL_MOD 3
    typedef union epoll_data { void *ptr; int fd; uint32_t u32; uint64_t u64; } epoll_data_t;
    struct epoll_event { uint32_t events; epoll_data_t data; };
    static inline int epoll_create1(int f) { (void)f; return -1; }
    static inline int epoll_ctl(int efd, int op, int fd, struct epoll_event *ev) { (void)efd; (void)op; (void)fd; (void)ev; return -1; }
    static inline int epoll_wait(int efd, struct epoll_event *ev, int max, int t) { (void)efd; (void)ev; (void)max; (void)t; return -1; }
    #endif
    EOF

    # sendfile (libuv)
    cat > $out/include/sys/sendfile.h << 'EOF'
    #ifndef _SYS_SENDFILE_H
    #define _SYS_SENDFILE_H
    #include <sys/types.h>
    static inline ssize_t sendfile(int out, int in, off_t *off, size_t cnt) { (void)out; (void)in; (void)off; (void)cnt; return -1; }
    #endif
    EOF

    # linux/perf_event.h (libuv)
    cat > $out/include/linux/perf_event.h << 'EOF'
    #ifndef _LINUX_PERF_EVENT_H
    #define _LINUX_PERF_EVENT_H
    #endif
    EOF
  '';

  # Compat header for libc++ on relibc — provides locale_t stubs, wchar funcs, etc.
  # Same header used by LLVM cross-compilation (see llvm-redox.nix).
  wcharCompat = pkgs.writeText "wchar_compat.h" ''
    #ifndef REDOX_WCHAR_COMPAT_H
    #define REDOX_WCHAR_COMPAT_H
    #if defined(__redox__)
    #ifndef _LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE
    #define _LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE
    #endif
    #endif
    /* C declarations needed by relibc (works in both C and C++) */
    #if defined(__redox__)
    #include <sys/types.h>
    #include <time.h>
    #ifdef __cplusplus
    extern "C" {
    #endif
    int openat(int, const char *, int, ...);
    int unlinkat(int, const char *, int);
    int utimensat(int, const char *, const struct timespec[2], int);
    extern char **environ;
    #ifdef __cplusplus
    }
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
    }
    #endif
    #endif
  '';

  src = pkgs.fetchurl {
    url = "https://github.com/Kitware/CMake/releases/download/v3.31.0/cmake-3.31.0.tar.gz";
    hash = "sha256-MAtx221p3MGrfFquYcvBqid4o+AMvZGLxyAgPjEUaMM=";
  };

  # CMake toolchain file for cross-compilation
  #
  # Key: uses -nostdlib to prevent host glibc CRT contamination, then
  # explicitly links relibc's crt0.o/crti.o/crtn.o + libc.a.
  # This matches the ccWrapper pattern from mk-c-library.nix.
  toolchainFile = pkgs.writeText "redox-toolchain.cmake" ''
    # Use "Linux" as system name so cmake selects POSIX code paths
    # (ProcessUNIX.c instead of ProcessWin32.c, etc.)
    # Redox is POSIX-like enough for cmake's platform abstractions.
    set(CMAKE_SYSTEM_NAME Linux)
    set(CMAKE_SYSTEM_PROCESSOR ${targetArch})

    # Use the CC/CXX wrappers that handle CRT startup files automatically
    set(CMAKE_C_COMPILER ${mkCLibrary.ccWrapper})
    set(CMAKE_CXX_COMPILER ${mkCLibrary.cxxWrapper})
    set(CMAKE_AR ${ar})
    set(CMAKE_RANLIB ${ranlib})
    set(CMAKE_NM ${nm})
    set(CMAKE_STRIP ${strip})
    set(CMAKE_LINKER ${ld})

    set(CMAKE_C_FLAGS_INIT "${baseCFlags} ${depCFlags} -isystem ${sysCompat}/include -include ${wcharCompat}")
    # C++ needs libc++ headers, wchar compat stubs, and -nostdlibinc to avoid host headers
    set(CMAKE_CXX_FLAGS_INIT "${baseCFlags} ${depCFlags} -isystem ${sysCompat}/include -nostdlibinc -isystem ${redox-libcxx}/include/c++/v1 -isystem ${sysroot}/include -include ${wcharCompat} -std=c++17")
    # Link flags: order matters! -lc++ -lc++abi must come after cmake objects.
    # CMAKE_EXE_LINKER_FLAGS_INIT goes before object files, so put libs in
    # CMAKE_CXX_STANDARD_LIBRARIES instead (goes after objects).
    set(CMAKE_EXE_LINKER_FLAGS_INIT "--target=${redoxTarget} --sysroot=${sysroot} -L${sysroot}/lib -L${redox-libcxx}/lib -L${stubLibs}/lib ${depLdFlags} -static -fuse-ld=lld")
    set(CMAKE_CXX_STANDARD_LIBRARIES "-lc++ -lc++abi -lunwind -lgcc" CACHE STRING "")

    set(CMAKE_FIND_ROOT_PATH ${sysroot} ${lib.concatStringsSep " " deps})
    set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

    # Tell cmake we're cross-compiling (so it doesn't try to run target binaries)
    set(CMAKE_CROSSCOMPILING TRUE)

    # Provide results for try_run() tests that can't execute on the host.
    # Redox is a 64-bit Unix-like OS — type sizes match Linux x86_64.
    set(KWSYS_LFS_WORKS 0)
    set(HAVE_ELF_H 0)
    set(HAVE_UNISTD_H 1)
    set(HAVE_ENVIRON_NOT_REQUIRE_PROTOTYPE 1)

    # Type sizes for libarchive's CHECK_TYPE_SIZE macro.
    # Format: HAVE_<NAME> = 1, <NAME> = <size_in_bytes>
    # These match Redox x86_64 (same as Linux x86_64).
    set(HAVE_DEV_T 1 CACHE INTERNAL "")
    set(DEV_T 8 CACHE INTERNAL "")
    set(HAVE_GID_T 1 CACHE INTERNAL "")
    set(GID_T 4 CACHE INTERNAL "")
    set(HAVE_ID_T 1 CACHE INTERNAL "")
    set(ID_T 4 CACHE INTERNAL "")
    set(HAVE_MODE_T 1 CACHE INTERNAL "")
    set(MODE_T 4 CACHE INTERNAL "")
    set(HAVE_OFF_T 1 CACHE INTERNAL "")
    set(OFF_T 8 CACHE INTERNAL "")
    set(HAVE_SIZE_T 1 CACHE INTERNAL "")
    set(SIZE_T 8 CACHE INTERNAL "")
    set(HAVE_SSIZE_T 1 CACHE INTERNAL "")
    set(SSIZE_T 8 CACHE INTERNAL "")
    set(HAVE_UID_T 1 CACHE INTERNAL "")
    set(UID_T 4 CACHE INTERNAL "")
    set(HAVE_PID_T 1 CACHE INTERNAL "")
    set(PID_T 4 CACHE INTERNAL "")
    set(HAVE_INTPTR_T 1 CACHE INTERNAL "")
    set(HAVE_UINTPTR_T 1 CACHE INTERNAL "")

    # Prevent try_run for libarchive's crypto checks
    set(HAVE_LIBMD 0 CACHE INTERNAL "")
    set(HAVE_LIBMD_MD5 0 CACHE INTERNAL "")
  '';

in
pkgs.stdenv.mkDerivation {
  pname = "cmake-redox";
  version = "3.31.0";

  inherit src;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    cmake
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.lld
    openssl
    pkg-config
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p build
    cd build

    # Disable libuv entirely — cmake server mode isn't needed on Redox.
    # libuv requires Linux-specific syscalls (epoll, inotify, prctl) that
    # relibc doesn't implement.
    # Replace the real cmlibuv source with a stub library.
    # libuv uses epoll/inotify/prctl which relibc doesn't implement.
    rm -rf ../Utilities/cmlibuv/src
    # Write stub C file with all required uv_* symbols
    cat > ../Utilities/cmlibuv/stub.c << 'UVCODE'
    #include <stddef.h>
    typedef struct uv_loop_s uv_loop_t;
    typedef struct uv_fs_s uv_fs_t;
    typedef struct uv_pipe_s uv_pipe_t;
    typedef struct uv_stream_s uv_stream_t;
    typedef struct uv_timeval64_s { long tv_sec; int tv_usec; } uv_timeval64_t;
    typedef void (*uv_alloc_cb)(void*, size_t, void*);
    typedef void (*uv_read_cb)(void*, long, const void*);
    typedef void (*uv_fs_cb)(uv_fs_t*);
    static char _default_loop[4096];
    uv_loop_t* uv_default_loop(void) { return (uv_loop_t*)_default_loop; }
    int uv_loop_close(uv_loop_t* l) { (void)l; return 0; }
    int uv_run(uv_loop_t* l, int m) { (void)l; (void)m; return 0; }
    void uv_disable_stdio_inheritance(void) {}
    int uv_fs_open(uv_loop_t* l, uv_fs_t* r, const char* p, int f, int m, uv_fs_cb cb) { (void)l;(void)r;(void)p;(void)f;(void)m;(void)cb; return -1; }
    void uv_fs_req_cleanup(uv_fs_t* r) { (void)r; }
    int uv_fs_stat(uv_loop_t* l, uv_fs_t* r, const char* p, uv_fs_cb cb) { (void)l;(void)r;(void)p;(void)cb; return -1; }
    int uv_gettimeofday(uv_timeval64_t* tv) { if(tv){tv->tv_sec=0;tv->tv_usec=0;} return 0; }
    int uv_pipe_open(uv_pipe_t* h, int fd) { (void)h;(void)fd; return -1; }
    int uv_read_start(uv_stream_t* s, uv_alloc_cb a, uv_read_cb r) { (void)s;(void)a;(void)r; return -1; }
    int uv_read_stop(uv_stream_t* s) { (void)s; return 0; }
    const char* uv_strerror(int e) { (void)e; return "libuv not available"; }
    int uv_translate_sys_error(int e) { return e; }
    /* Additional stubs for cmake's process/timer/signal support */
    typedef struct uv_async_s uv_async_t;
    typedef struct uv_idle_s uv_idle_t;
    typedef struct uv_signal_s uv_signal_t;
    typedef struct uv_timer_s uv_timer_t;
    typedef struct uv_tty_s uv_tty_t;
    typedef struct uv_process_s uv_process_t;
    typedef struct uv_process_options_s uv_process_options_t;
    typedef void (*uv_async_cb)(uv_async_t*);
    typedef void (*uv_idle_cb)(uv_idle_t*);
    typedef void (*uv_signal_cb)(uv_signal_t*, int);
    typedef void (*uv_timer_cb)(uv_timer_t*);
    int uv_async_init(uv_loop_t* l, uv_async_t* a, uv_async_cb cb) { (void)l;(void)a;(void)cb; return -1; }
    int uv_async_send(uv_async_t* a) { (void)a; return -1; }
    int uv_idle_init(uv_loop_t* l, uv_idle_t* h) { (void)l;(void)h; return -1; }
    int uv_idle_start(uv_idle_t* h, uv_idle_cb cb) { (void)h;(void)cb; return -1; }
    int uv_loop_init(uv_loop_t* l) { (void)l; return 0; }
    int uv_pipe_init(uv_loop_t* l, uv_pipe_t* h, int ipc) { (void)l;(void)h;(void)ipc; return -1; }
    int uv_signal_init(uv_loop_t* l, uv_signal_t* h) { (void)l;(void)h; return -1; }
    int uv_signal_start(uv_signal_t* h, uv_signal_cb cb, int s) { (void)h;(void)cb;(void)s; return -1; }
    int uv_signal_stop(uv_signal_t* h) { (void)h; return 0; }
    int uv_spawn(uv_loop_t* l, uv_process_t* p, const uv_process_options_t* o) { (void)l;(void)p;(void)o; return -1; }
    int uv_timer_init(uv_loop_t* l, uv_timer_t* h) { (void)l;(void)h; return -1; }
    int uv_timer_start(uv_timer_t* h, uv_timer_cb cb, unsigned long long t, unsigned long long r) { (void)h;(void)cb;(void)t;(void)r; return -1; }
    int uv_timer_stop(uv_timer_t* h) { (void)h; return 0; }
    int uv_tty_init(uv_loop_t* l, uv_tty_t* h, int fd, int r) { (void)l;(void)h;(void)fd;(void)r; return -1; }
    /* Stubs for filesystem operations used by cmSystemTools */
    typedef struct uv_handle_s uv_handle_t;
    typedef struct uv_write_s uv_write_t;
    typedef struct uv_buf_s { char *base; size_t len; } uv_buf_t;
    typedef void (*uv_close_cb)(uv_handle_t*);
    typedef void (*uv_write_cb)(uv_write_t*, int);
    void uv_close(uv_handle_t* h, uv_close_cb cb) { (void)h; if(cb) cb(h); }
    int uv_is_closing(const uv_handle_t* h) { (void)h; return 1; }
    int uv_idle_stop(uv_idle_t* h) { (void)h; return 0; }
    int uv_fs_symlink(uv_loop_t* l, uv_fs_t* r, const char* p, const char* n, int f, uv_fs_cb cb) { (void)l;(void)r;(void)p;(void)n;(void)f;(void)cb; return -1; }
    int uv_fs_link(uv_loop_t* l, uv_fs_t* r, const char* p, const char* n, uv_fs_cb cb) { (void)l;(void)r;(void)p;(void)n;(void)cb; return -1; }
    int uv_fs_get_system_error(const uv_fs_t* r) { (void)r; return -1; }
    int uv_write(uv_write_t* r, uv_stream_t* h, const uv_buf_t b[], unsigned int n, uv_write_cb cb) { (void)r;(void)h;(void)b;(void)n;(void)cb; return -1; }
    /* Stubs for ctest process management */
    uv_buf_t uv_buf_init(char* base, unsigned int len) { uv_buf_t buf; buf.base = base; buf.len = len; return buf; }
    int uv_cpumask_size(void) { return 0; }
    int uv_process_kill(uv_process_t* h, int sig) { (void)h; (void)sig; return -1; }
    int uv_is_active(const uv_handle_t* h) { (void)h; return 0; }
    int uv_is_readable(const uv_stream_t* s) { (void)s; return 0; }
    int uv_is_writable(const uv_stream_t* s) { (void)s; return 0; }
  UVCODE
    # Write minimal CMakeLists.txt — just builds stub.c into a static lib
    printf 'project(libuv C)\nadd_library(cmlibuv STATIC stub.c)\ntarget_include_directories(cmlibuv PUBLIC include)\n' > ../Utilities/cmlibuv/CMakeLists.txt

    cmake .. \
      -DCMAKE_TOOLCHAIN_FILE=${toolchainFile} \
      -DCMAKE_INSTALL_PREFIX=$out \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF \
      \
      -DCMAKE_USE_SYSTEM_ZLIB=ON \
      -DZLIB_INCLUDE_DIR=${redox-zlib}/include \
      -DZLIB_LIBRARY=${redox-zlib}/lib/libz.a \
      \
      -DCMAKE_USE_SYSTEM_ZSTD=ON \
      -Dzstd_INCLUDE_DIR=${redox-zstd}/include \
      -Dzstd_LIBRARY=${redox-zstd}/lib/libzstd.a \
      \
      -DCMAKE_USE_SYSTEM_BZIP2=ON \
      -DBZIP2_INCLUDE_DIR=${redox-bzip2}/include \
      -DBZIP2_LIBRARIES=${redox-bzip2}/lib/libbz2.a \
      \
      -DCMAKE_USE_SYSTEM_EXPAT=ON \
      -DEXPAT_INCLUDE_DIR=${redox-expat}/include \
      -DEXPAT_LIBRARY=${redox-expat}/lib/libexpat.a \
      \
      -DCMAKE_USE_SYSTEM_CURL=OFF \
      -DCMAKE_USE_SYSTEM_LIBARCHIVE=OFF \
      -DCMAKE_USE_SYSTEM_LIBUV=OFF \
      -DCMake_HAVE_CXX_MAKE_UNIQUE=ON \
      -DCMAKE_USE_SYSTEM_NGHTTP2=OFF \
      \
      -DCMAKE_USE_OPENSSL=OFF \
      -DCMAKE_USE_SYSTEM_FORM=OFF \
      -DCMAKE_USE_SYSTEM_JSONCPP=OFF \
      -DCMAKE_USE_SYSTEM_CPPDAP=OFF \
      -DCMAKE_USE_SYSTEM_LIBRHASH=OFF \
      \
      -DBUILD_QtDialog=OFF \
      -DBUILD_CursesDialog=OFF \
      -DCMake_ENABLE_DEBUGGER=OFF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install
    # Clean up docs
    rm -rf $out/share/man $out/share/doc 2>/dev/null || true
    runHook postInstall
  '';

  meta = {
    description = "CMake build system for Redox OS";
    homepage = "https://cmake.org";
  };
}
