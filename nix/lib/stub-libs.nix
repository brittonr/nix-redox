# Shared stub libraries for Redox cross-compilation
#
# These stub implementations provide empty unwinding functions required
# by Rust's panic infrastructure. Since we build with panic=abort, these
# are never actually called, but the linker needs the symbols.
#
# This derivation is built once and shared by all cross-compiled packages,
# eliminating ~15 lines of duplicated code from each package.

{ pkgs, redoxTarget }:

pkgs.stdenv.mkDerivation {
  pname = "redox-stub-libs";
  version = "1.0.0";

  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.llvmPackages.clang-unwrapped
    pkgs.llvmPackages.llvm
  ];

  buildPhase = ''
    runHook preBuild

    cat > unwind_stubs.c << 'EOF'
    // Stub implementations for unwinding functions
    // These are required by Rust's panic infrastructure but never called
    // when building with panic=abort.

    typedef void* _Unwind_Reason_Code;
    typedef void* _Unwind_Context;
    typedef void* _Unwind_Ptr;

    _Unwind_Reason_Code _Unwind_Backtrace(void* fn, void* arg) { return 0; }
    _Unwind_Ptr _Unwind_GetIP(_Unwind_Context* ctx) { return 0; }
    _Unwind_Ptr _Unwind_GetTextRelBase(_Unwind_Context* ctx) { return 0; }
    _Unwind_Ptr _Unwind_GetDataRelBase(_Unwind_Context* ctx) { return 0; }
    _Unwind_Ptr _Unwind_GetRegionStart(_Unwind_Context* ctx) { return 0; }
    _Unwind_Ptr _Unwind_GetCFA(_Unwind_Context* ctx) { return 0; }
    void* _Unwind_FindEnclosingFunction(void* pc) { return 0; }
    EOF

    ${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
      --target=${redoxTarget} \
      -c unwind_stubs.c \
      -o unwind_stubs.o

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib

    # Create static libraries that provide the required symbols
    ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs $out/lib/libgcc_eh.a unwind_stubs.o
    ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs $out/lib/libgcc.a unwind_stubs.o
    ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs $out/lib/libunwind.a unwind_stubs.o

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Stub unwinding libraries for Redox OS cross-compilation";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
