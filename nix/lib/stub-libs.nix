# Shared stub libraries for Redox cross-compilation
#
# These stub implementations provide empty unwinding functions required
# by Rust's panic infrastructure. Since we build with panic=abort, these
# are never actually called, but the linker needs the symbols.
#
# CRITICAL: Each stub function is compiled into its OWN object file.
# Static archive (.a) linking pulls in entire .o files at a time. If all
# stubs share one .o, needing _Unwind_Backtrace (for libstd backtraces)
# also drags in _Unwind_RaiseException — which breaks panic=unwind
# binaries like rustc. Separate .o files let the linker pull in only the
# backtrace/info stubs without poisoning the active unwind pathway.
#
# See: openspec/changes/fix-relibc-panic-abort/ for the full diagnosis.

{ pkgs, redoxTarget }:

let
  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  ar = "${pkgs.llvmPackages.llvm}/bin/llvm-ar";
in
pkgs.stdenv.mkDerivation {
  pname = "redox-stub-libs";
  version = "2.0.0";

  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.llvmPackages.clang-unwrapped
    pkgs.llvmPackages.llvm
  ];

  buildPhase = ''
    runHook preBuild

    # Common type definitions shared by all stubs
    cat > types.h << 'TYPES'
    typedef void* _Unwind_Reason_Code;
    typedef void* _Unwind_Action;
    typedef void* _Unwind_Context;
    typedef void* _Unwind_Exception;
    typedef void* _Unwind_Ptr;
    typedef void* _Unwind_Word;
    typedef unsigned long uintptr_t;
    TYPES

    # --- Backtrace / info stubs (one function per .o) ---
    # These are referenced by libstd for backtrace support. With panic=abort
    # they're never called at runtime, but the linker needs them resolved.

    echo '#include "types.h"
    _Unwind_Reason_Code _Unwind_Backtrace(void* fn, void* arg) { return 0; }' > stub_backtrace.c

    echo '#include "types.h"
    _Unwind_Ptr _Unwind_GetIP(_Unwind_Context* ctx) { return 0; }' > stub_getip.c

    echo '#include "types.h"
    _Unwind_Ptr _Unwind_GetTextRelBase(_Unwind_Context* ctx) { return 0; }' > stub_gettextrelbase.c

    echo '#include "types.h"
    _Unwind_Ptr _Unwind_GetDataRelBase(_Unwind_Context* ctx) { return 0; }' > stub_getdatarelbase.c

    echo '#include "types.h"
    _Unwind_Ptr _Unwind_GetRegionStart(_Unwind_Context* ctx) { return 0; }' > stub_getregionstart.c

    echo '#include "types.h"
    _Unwind_Ptr _Unwind_GetCFA(_Unwind_Context* ctx) { return 0; }' > stub_getcfa.c

    echo '#include "types.h"
    void* _Unwind_FindEnclosingFunction(void* pc) { return 0; }' > stub_findenclosing.c

    echo '#include "types.h"
    _Unwind_Ptr _Unwind_GetLanguageSpecificData(_Unwind_Context* ctx) { return 0; }' > stub_getlsd.c

    echo '#include "types.h"
    uintptr_t _Unwind_GetIPInfo(_Unwind_Context* ctx, int* ip_before_insn) {
        if (ip_before_insn) *ip_before_insn = 0;
        return 0;
    }' > stub_getipinfo.c

    echo '#include "types.h"
    void _Unwind_SetGR(_Unwind_Context* ctx, int index, uintptr_t value) { }' > stub_setgr.c

    echo '#include "types.h"
    void _Unwind_SetIP(_Unwind_Context* ctx, uintptr_t value) { }' > stub_setip.c

    # --- Active unwind stubs (one function per .o) ---
    # These are referenced by libpanic_unwind and libstd (_Unwind_Resume).
    # With panic=abort they're dead code but still need linker resolution.
    #
    # Return 0 from these stubs. With panic=abort they're dead code.
    # For panic=unwind binaries (rustc), returning 0 causes the runtime
    # to print "failed to initiate panic, error 0" then abort — not ideal
    # but harmless. abort()-on-call was tried but breaks DSO init paths
    # that touch _Unwind_Resume during C++ landing pad cleanup.

    echo '#include "types.h"
    _Unwind_Reason_Code _Unwind_RaiseException(_Unwind_Exception* exc) { return 0; }' > stub_raise.c

    echo '#include "types.h"
    void _Unwind_Resume(_Unwind_Exception* exc) { }' > stub_resume.c

    echo '#include "types.h"
    void _Unwind_DeleteException(_Unwind_Exception* exc) { }' > stub_delete.c

    # --- EH frame registration (one .o for the group) ---
    # Needed by LLVM ORC JIT. These are no-ops on Redox.
    echo 'void __register_frame(void* begin) { (void)begin; }
    void __deregister_frame(void* begin) { (void)begin; }
    void __register_frame_info(void* begin, void* ob) { (void)begin; (void)ob; }
    void __deregister_frame_info(void* begin) { (void)begin; }' > stub_ehframe.c

    # Compile each stub into its own .o
    for src in stub_*.c; do
      obj="''${src%.c}.o"
      ${cc} --target=${redoxTarget} -c "$src" -o "$obj"
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib

    # Create static libraries from individual .o files.
    # Each symbol lives in its own .o, so the linker only pulls in
    # the specific stubs it needs — not the entire set.
    ${ar} crs $out/lib/libgcc_eh.a stub_*.o
    ${ar} crs $out/lib/libgcc.a stub_*.o
    ${ar} crs $out/lib/libunwind.a stub_*.o

    echo "=== Stub library contents ==="
    ${ar} t $out/lib/libgcc.a
    echo "=== Stub symbol count ==="
    ${pkgs.llvmPackages.llvm}/bin/llvm-nm $out/lib/libgcc.a | grep -c "^[0-9a-f].*T " || true

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Stub unwinding libraries for Redox OS cross-compilation";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
