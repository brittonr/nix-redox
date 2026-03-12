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
  rustc-redox,
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

    # ===== Rust allocator shim (liballoc_shim.a) =====
    # When rustc links a binary, it generates an "allocator shim" object file
    # that wires __rust_alloc → __rdl_alloc (the default System allocator in std).
    # For manual two-step linking (rustc --emit=obj + ld.lld), this shim is missing.
    #
    # The symbols use Rust v0 mangling with the __rustc crate hash. We extract
    # the exact mangled names from the rlibs at build time so this stays correct
    # even when the hash changes between rustc versions.
    echo "Creating allocator shim..."

    # Extract the crate hash from any defined __rustc symbol in the rlibs
    RLIB_DIR="$(echo ${rustc-redox}/lib/rustlib/x86_64-unknown-redox/lib)"
    HASH_PREFIX=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --defined-only \
      "$RLIB_DIR"/libstd-*.rlib 2>/dev/null \
      | grep "CshD9Gi206LEK_7___rustc" | head -1 \
      | grep -o '_RNvCs[^_]*_7___rustc' || true)

    if [ -z "$HASH_PREFIX" ]; then
      echo "WARNING: Could not extract __rustc crate hash from rlibs, skipping alloc shim"
    else
      echo "  __rustc hash prefix: $HASH_PREFIX"

      # Find the mangled names of the __rdl_* target functions
      RDL_ALLOC=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --defined-only "$RLIB_DIR"/libstd-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*rdl_alloc$" | awk '{print $NF}')
      RDL_DEALLOC=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --defined-only "$RLIB_DIR"/libstd-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*rdl_dealloc$" | awk '{print $NF}')
      RDL_REALLOC=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --defined-only "$RLIB_DIR"/libstd-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*rdl_realloc$" | awk '{print $NF}')
      RDL_ALLOC_ZEROED=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --defined-only "$RLIB_DIR"/libstd-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*rdl_alloc_zeroed$" | awk '{print $NF}')
      RDL_OOM=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --defined-only "$RLIB_DIR"/liballoc-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*rdl_oom$" | awk '{print $NF}')

      echo "  rdl_alloc: $RDL_ALLOC"
      echo "  rdl_dealloc: $RDL_DEALLOC"
      echo "  rdl_realloc: $RDL_REALLOC"
      echo "  rdl_alloc_zeroed: $RDL_ALLOC_ZEROED"
      echo "  rdl_oom: $RDL_OOM"

      # Find the mangled names of the undefined symbols we need to provide
      RUST_ALLOC=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --undefined-only "$RLIB_DIR"/liballoc-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*12___rust_alloc$" | awk '{print $NF}' | head -1)
      RUST_DEALLOC=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --undefined-only "$RLIB_DIR"/liballoc-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*14___rust_dealloc$" | awk '{print $NF}' | head -1)
      RUST_REALLOC=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --undefined-only "$RLIB_DIR"/liballoc-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*14___rust_realloc$" | awk '{print $NF}' | head -1)
      RUST_ALLOC_ZEROED=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --undefined-only "$RLIB_DIR"/liballoc-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*19___rust_alloc_zeroed$" | awk '{print $NF}' | head -1)
      RUST_ALLOC_ERROR=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --undefined-only "$RLIB_DIR"/liballoc-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*26___rust_alloc_error_handler$" | awk '{print $NF}' | head -1)
      RUST_SHOULD_PANIC=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --undefined-only "$RLIB_DIR"/libstd-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*42___rust_alloc_error_handler_should_panic_v2$" | awk '{print $NF}' | head -1)
      RUST_UNSTABLE=$(${pkgs.llvmPackages.llvm}/bin/llvm-nm --undefined-only "$RLIB_DIR"/liballoc-*.rlib 2>/dev/null | grep "CshD9Gi206LEK.*35___rust_no_alloc_shim_is_unstable_v2$" | awk '{print $NF}' | head -1)

      cat > $TMPDIR/alloc_shim.S << SHIMEOF
    /* Rust allocator shim for manual linking.
     * Provides the symbols normally generated by rustc's codegen_allocator().
     * Redirects __rust_alloc → __rdl_alloc (default System allocator in std). */
    .text

    /* __rust_alloc(size: usize, align: usize) -> *mut u8 */
    .globl $RUST_ALLOC
    $RUST_ALLOC:
        jmp $RDL_ALLOC

    /* __rust_dealloc(ptr: *mut u8, size: usize, align: usize) */
    .globl $RUST_DEALLOC
    $RUST_DEALLOC:
        jmp $RDL_DEALLOC

    /* __rust_realloc(ptr: *mut u8, old_size: usize, align: usize, new_size: usize) -> *mut u8 */
    .globl $RUST_REALLOC
    $RUST_REALLOC:
        jmp $RDL_REALLOC

    /* __rust_alloc_zeroed(size: usize, align: usize) -> *mut u8 */
    .globl $RUST_ALLOC_ZEROED
    $RUST_ALLOC_ZEROED:
        jmp $RDL_ALLOC_ZEROED

    /* __rust_alloc_error_handler(size: usize, align: usize) -> ! */
    .globl $RUST_ALLOC_ERROR
    $RUST_ALLOC_ERROR:
        jmp $RDL_OOM

    /* __rust_alloc_error_handler_should_panic_v2() -> i8 { return 0; }
     * OomStrategy::Abort = 0 (don't panic, just abort on OOM) */
    .globl $RUST_SHOULD_PANIC
    $RUST_SHOULD_PANIC:
        xorl %eax, %eax
        retq

    /* __rust_no_alloc_shim_is_unstable_v2() -> void { }
     * Marker function, no-op */
    .globl $RUST_UNSTABLE
    $RUST_UNSTABLE:
        retq
    SHIMEOF

      ${pkgs.llvmPackages.clang}/bin/clang \
        --target=x86_64-unknown-redox \
        -c $TMPDIR/alloc_shim.S \
        -o $TMPDIR/alloc_shim.o

      ${pkgs.llvmPackages.llvm}/bin/llvm-ar rcs \
        $out/${sysrootRelPath}/lib/liballoc_shim.a \
        $TMPDIR/alloc_shim.o

      echo "Allocator shim created: $(${pkgs.llvmPackages.llvm}/bin/llvm-nm $out/${sysrootRelPath}/lib/liballoc_shim.a | grep -c "^[0-9a-f].*T ") symbols"
    fi

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
    #
    # RESPONSE FILES: rustc passes linker arguments via @file (response file)
    # when there are many arguments (e.g., proc-macros with 50+ args). The CC
    # wrapper must expand @file, process the args, and write a clean @file
    # for lld. Response file format: one arg per line, optionally quoted.

    S=/usr/lib/redox-sysroot
    # Use lld-wrapper instead of bare ld.lld to get a 16MB stack for the linker.
    # The Redox kernel only gives ~8KB main-thread stack, which overflows under
    # parallel link invocations (JOBS>=2). lld-wrapper spawns a thread with a
    # large stack and exec()s ld.lld from it.
    LLD=/nix/system/profile/bin/lld-wrapper
    CLANG=/nix/system/profile/bin/clang
    ERR=/tmp/.cc-wrapper-stderr

    # Log raw input args for debugging
    printf '%s\n' "--- CC wrapper invocation ---" "$@" > /tmp/.cc-wrapper-raw-args

    # Compile-only detection: if any arg is -c, -S, -E, -M, or -MM, this is
    # a compile (not link) invocation. Pass through to clang with sysroot.
    # Ring's build script (cc crate) calls `cc -E` for compiler detection
    # and `cc -c` to compile .c → .o files.
    #
    # We use -isystem instead of --sysroot to avoid clang's sysroot logic
    # overriding its resource header search. The clang resource headers
    # (stddef.h, stdarg.h) are in the sysroot's lib/clang/21/include/ AND
    # in the clang installation's lib/clang/21/include/.
    for arg in "$@"; do
      case "$arg" in
        -c|-S|-E|-M|-MM)
          # Find clang resource header dir (version-agnostic glob)
          CLANG_RES=""
          for d in "$S"/lib/clang/*/include; do
            if [ -d "$d" ]; then
              CLANG_RES="$d"
              break
            fi
          done
          # -no-canonical-prefixes: prevents clang from calling realpath()
          # on itself. On Redox, realpath returns "file:/path" which breaks
          # clang's executable self-discovery (InstalledDir becomes empty).
          # -resource-dir: explicit path since clang can't find it without
          # a working InstalledDir.
          exec "$CLANG" \
            -no-canonical-prefixes \
            ''${CLANG_RES:+-resource-dir "''${CLANG_RES%/include}"} \
            -isystem "$S/include" \
            "$@"
          ;;
      esac
    done

    # Expand response files (@file) into RAW_ARGS array
    RAW_ARGS=()
    for arg in "$@"; do
      case "$arg" in
        @*)
          respfile="''${arg#@}"
          if [ -f "$respfile" ]; then
            # Read response file: one arg per line, strip surrounding quotes
            while IFS= read -r line || [ -n "$line" ]; do
              # Strip leading/trailing whitespace
              line="''${line#"''${line%%[![:space:]]*}"}"
              line="''${line%"''${line##*[![:space:]]}"}"
              # Skip empty lines
              [ -z "$line" ] && continue
              # Strip surrounding double quotes if present
              case "$line" in
                \"*\") line="''${line#\"}"; line="''${line%\"}" ;;
              esac
              RAW_ARGS+=("$line")
            done < "$respfile"
          else
            RAW_ARGS+=("$arg")
          fi
          ;;
        *)
          RAW_ARGS+=("$arg")
          ;;
      esac
    done

    # Detect -shared flag (for proc-macro .so builds)
    IS_SHARED=0
    for arg in "''${RAW_ARGS[@]}"; do
      if [ "$arg" = "-shared" ]; then
        IS_SHARED=1
        break
      fi
    done

    # Filter out GCC flags that ld.lld doesn't understand.
    # Handle -Wl, prefix stripping with comma splitting:
    #   -Wl,--version-script=/tmp/foo  ->  --version-script=/tmp/foo
    #   -Wl,-z,relro,-z,now           ->  -z relro -z now
    #   -Wl,-Bstatic                   ->  -Bstatic
    ARGS=()
    for arg in "''${RAW_ARGS[@]}"; do
      case "$arg" in
        -m64|-m32)         ;;    # lld uses -m elf_x86_64 not -m64
        -Wl,*)
          # Strip -Wl, prefix and split on commas into separate args
          stripped="''${arg#-Wl,}"
          IFS=',' read -ra parts <<< "$stripped"
          for part in "''${parts[@]}"; do
            ARGS+=("$part")
          done
          ;;
        -nodefaultlibs)    ;;
        -nostdlib)         ;;
        -lgcc_s)           ;;    # no libgcc_s; symbols are in libgcc_eh.a
        *)                 ARGS+=("$arg") ;;
      esac
    done

    if [ "$IS_SHARED" = "1" ]; then
      # Shared library (proc-macro .so): no crt0.o (provides _start for exes).
      # Keep crti/crtn for .init/.fini sections. Use dynamic libc.

      # For proc-macros, inject version script symbols and use --undefined-version
      # to avoid errors from symbols not present in every .so.
      for i in "''${!ARGS[@]}"; do
        case "''${ARGS[$i]}" in
          --version-script=*)
            vs="''${ARGS[$i]#--version-script=}"
            if [ -f "$vs" ]; then
              # Add relibc init symbols before "local: *;" to prevent hiding them
              sed -i '/^[[:space:]]*local:/i\    __relibc_init_ns_fd;\n    __relibc_init_proc_fd;\n    __relibc_init_cwd_ptr;\n    __relibc_init_cwd_len;\n    __relibc_init_environ;' "$vs" 2>/dev/null
            fi
            ;;
        esac
      done

      # Log the full command for debugging
      printf '%s\n' "$LLD" "$S/lib/crti.o" "''${ARGS[@]}" "--undefined-version" "-L" "$S/lib" "-lc" "-lgcc_eh" "$S/lib/crtn.o" > /tmp/.cc-wrapper-shared-cmd
      "$LLD" \
        "$S/lib/crti.o" \
        "''${ARGS[@]}" \
        --undefined-version \
        -L "$S/lib" -lc -lgcc_eh \
        "$S/lib/crtn.o" \
        > /dev/null 2> "$ERR" &
    else
      # Executable: full CRT + static libc
      "$LLD" \
        "$S/lib/crt0.o" "$S/lib/crti.o" \
        "''${ARGS[@]}" \
        -L "$S/lib" -l:libc.a -l:libpthread.a -l:libgcc_eh.a \
        "$S/lib/crtn.o" \
        > /dev/null 2> "$ERR" &
    fi
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
