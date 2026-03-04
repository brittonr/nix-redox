# Redox sysroot + CC wrapper for on-guest compilation
#
# Bundles relibc headers + static libs + CRT files + clang resource headers
# into a standard sysroot, and provides a `cc` wrapper script that rustc/cargo
# use as their linker when building Rust code on Redox.
#
# Layout in /nix/store/<hash>-redox-sysroot/:
#   sysroot/
#     include/          — relibc headers (stdio.h, stdlib.h, etc.)
#     lib/              — libc.a, libpthread.a, crt0.o, crti.o, crtn.o
#     lib/clang/21/     — clang resource headers (intrinsics, builtins)
#   bin/
#     cc                — CC wrapper (clang → lld with sysroot flags)
#
# The CC wrapper is what rustc invokes for the final link step.
# It adds CRT files, sysroot paths, and drives lld.

{
  pkgs,
  lib,
  relibc,
  redoxTarget,
  redox-llvm,
  redox-libcxx,
  ...
}:

let
  relibcDir = "${relibc}/${redoxTarget}";

  # Path where the sysroot will be installed on-guest
  # (relative to the package's store path)
  sysrootRelPath = "sysroot";
in
pkgs.runCommand "redox-sysroot"
  {
    pname = "redox-sysroot";
    nativeBuildInputs = [ pkgs.llvmPackages.lld ];
  }
  ''
    mkdir -p $out/${sysrootRelPath} $out/bin

    # ===== Headers =====
    cp -r ${relibcDir}/include $out/${sysrootRelPath}/include

    # ===== Libraries and CRT files =====
    mkdir -p $out/${sysrootRelPath}/lib
    for f in crt0.o crt1.o crti.o crtn.o libc.a libpthread.a libdl.a libm.a librt.a libc.so libc.so.6 ld64.so.1; do
      if [ -e "${relibcDir}/lib/$f" ]; then
        cp -a "${relibcDir}/lib/$f" "$out/${sysrootRelPath}/lib/$f"
      fi
    done

    # ===== Stub libgcc_eh.a and libgcc.a (unwind symbols) =====
    # libstd references _Unwind_* symbols for backtraces and panic_unwind.
    # On Redox we use panic=abort, so these are never called at runtime.
    # Provide stub implementations so the linker can resolve them.
    echo "Creating stub libgcc_eh.a..."
    cat > $TMPDIR/unwind_stubs.c << 'STUBS'
    /* Stub implementations of GCC/LLVM unwind ABI functions.
     * These are referenced by libstd for backtrace/panic support but
     * never called when panic=abort is used. */
    typedef int _Unwind_Reason_Code;
    typedef void* _Unwind_Context;
    typedef void* _Unwind_Exception;
    typedef _Unwind_Reason_Code (*_Unwind_Trace_Fn)(_Unwind_Context*, void*);

    unsigned long _Unwind_GetIP(_Unwind_Context* c) { return 0; }
    void* _Unwind_FindEnclosingFunction(void* pc) { return 0; }
    _Unwind_Reason_Code _Unwind_Backtrace(_Unwind_Trace_Fn fn, void* data) { return 0; }
    unsigned long _Unwind_GetCFA(_Unwind_Context* c) { return 0; }
    unsigned long _Unwind_GetTextRelBase(_Unwind_Context* c) { return 0; }
    unsigned long _Unwind_GetDataRelBase(_Unwind_Context* c) { return 0; }
    void _Unwind_SetIP(_Unwind_Context* c, unsigned long val) {}
    void _Unwind_SetGR(_Unwind_Context* c, int reg, unsigned long val) {}
    unsigned long _Unwind_GetGR(_Unwind_Context* c, int reg) { return 0; }
    _Unwind_Reason_Code _Unwind_RaiseException(_Unwind_Exception* e) { return 0; }
    void _Unwind_Resume(_Unwind_Exception* e) {}
    void _Unwind_DeleteException(_Unwind_Exception* e) {}
    void* _Unwind_GetLanguageSpecificData(_Unwind_Context* c) { return 0; }
    unsigned long _Unwind_GetRegionStart(_Unwind_Context* c) { return 0; }
    unsigned long _Unwind_GetIPInfo(_Unwind_Context* c, int* ip_before_insn) {
      if (ip_before_insn) *ip_before_insn = 0;
      return 0;
    }
    int __gcc_personality_v0() { return 0; }
    STUBS

    ${pkgs.llvmPackages.clang}/bin/clang \
      --target=x86_64-unknown-redox \
      --sysroot=$out/${sysrootRelPath} \
      -nostdlib -ffreestanding \
      -c $TMPDIR/unwind_stubs.c \
      -o $TMPDIR/unwind_stubs.o

    ${pkgs.llvmPackages.llvm}/bin/llvm-ar rcs \
      $out/${sysrootRelPath}/lib/libgcc_eh.a \
      $TMPDIR/unwind_stubs.o

    # Also create libgcc.a (some linker invocations look for -lgcc)
    cp $out/${sysrootRelPath}/lib/libgcc_eh.a \
       $out/${sysrootRelPath}/lib/libgcc.a

    echo "Stub libgcc_eh.a and libgcc.a created"

    # ===== Dynamic linker and shared libc for /lib/ =====
    # Dynamically linked binaries (like rustc) need ld64.so.1 at /lib/
    # and libc.so at a findable path. The build module will symlink these.
    mkdir -p $out/lib
    cp "${relibcDir}/lib/ld64.so.1" "$out/lib/ld64.so.1"
    cp "${relibcDir}/lib/libc.so" "$out/lib/libc.so"
    ln -sf libc.so "$out/lib/libc.so.6"

    # ===== Clang resource headers (intrinsics like stdint.h, stdarg.h, etc.) =====
    # These are needed when clang is used as a CC.
    if [ -d "${redox-llvm}/lib/clang" ]; then
      cp -r "${redox-llvm}/lib/clang" "$out/${sysrootRelPath}/lib/clang"
    fi

    # ===== CC wrapper =====
    # This script is what `rustc` invokes when it needs to link a binary.
    # The Redox target uses LinkerFlavor::Gcc, so rustc passes GCC-style flags
    # (-L, -l, -o, etc.). Clang understands these and drives lld.
    #
    # When invoked for compilation (-c, -S, -E), passes through to clang
    # with the sysroot include paths.
    # When invoked for linking, adds CRT files and drives lld.
    cat > $out/bin/cc << 'WRAPPER'
    #!/nix/system/profile/bin/bash
    # CC wrapper for Redox self-hosting — invokes ld.lld directly.
    #
    # Uses bash (not Ion) because Ion's argument parser eats -o.
    #
    # CRITICAL WORKAROUND: Rust std's Command::output() on Redox crashes
    # (Invalid opcode in read2/poll) when reading from pipes connected to
    # a child process that runs for more than trivial time.
    #
    # Fix: Close stdout/stderr (sends EOF to rustc's pipes) BEFORE running
    # ld.lld. ld.lld's output goes to temp files for post-mortem diagnosis.

    S=/usr/lib/redox-sysroot
    LLD=/nix/system/profile/bin/ld.lld
    ERR=/tmp/.cc-wrapper-stderr

    # Filter out GCC flags that ld.lld doesn't understand
    ARGS=()
    for arg in "$@"; do
      case "$arg" in
        -m64|-m32)         ;;    # lld uses -m elf_x86_64 not -m64
        -Wl,*)             ARGS+=("''${arg#-Wl,}") ;;
        -nodefaultlibs)    ;;
        -nostdlib)         ;;
        *)                 ARGS+=("$arg") ;;
      esac
    done

    # Run ld.lld in background with output redirected to files
    "$LLD" \
      "$S/lib/crt0.o" "$S/lib/crti.o" \
      "''${ARGS[@]}" \
      -L "$S/lib" -l:libc.a -l:libpthread.a -l:libgcc_eh.a \
      "$S/lib/crtn.o" \
      > /dev/null 2> "$ERR" &
    pid=$!

    # Close stdout/stderr — sends EOF to rustc's pipes immediately
    exec 1>&- 2>&-

    # Wait for ld.lld to finish
    wait $pid
    exit $?
    WRAPPER

    # Arg-capture "linker" — writes its arguments to /tmp/linker-args.txt then exits 0.
    # Used to see what arguments rustc passes to the linker without actually linking.
    cat > $out/bin/cc-print-args << 'PRINTARGS'
    #!/nix/system/profile/bin/bash
    printf '%s\n' "$@" > /tmp/linker-args.txt
    PRINTARGS
    chmod +x $out/bin/cc-print-args
    chmod 755 $out/bin/cc

    # Also provide 'gcc' symlink (some tools look for gcc)
    ln -s cc $out/bin/gcc

    # ===== libstdc++.so.6 shim from libc++ =====
    # librustc_driver.so was linked against libstdc++.so.6 (host GCC C++ runtime).
    # On Redox we use libc++. Create a shared library from libc++.a that provides
    # all C++ runtime symbols, named libstdc++.so.6 for ABI compatibility.
    # (Both implement the Itanium C++ ABI, so symbols are compatible.)
    echo "Building libstdc++.so.6 shim from libc++..."
    # Use ld.lld directly (clang tries to invoke "gcc" for Redox target which doesn't exist)
    ${pkgs.llvmPackages.lld}/bin/ld.lld \
      -shared \
      --whole-archive \
        ${redox-libcxx}/lib/libc++.a \
        ${redox-libcxx}/lib/libc++abi.a \
        ${redox-libcxx}/lib/libunwind.a \
      --no-whole-archive \
      -L${relibcDir}/lib \
      ${relibcDir}/lib/libc.a \
      ${relibcDir}/lib/libpthread.a \
      --soname=libstdc++.so.6 \
      -o $out/${sysrootRelPath}/lib/libstdc++.so.6

    echo "=== Sysroot size ==="
    du -sh $out/
    du -sh $out/${sysrootRelPath}/
    echo "=== Sysroot file count ==="
    find $out -type f | wc -l
  ''
