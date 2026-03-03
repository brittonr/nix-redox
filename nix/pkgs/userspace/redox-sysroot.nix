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
    #!/bin/ion
    # CC wrapper for Redox self-hosting
    # Wraps clang with the correct sysroot, CRT files, and linker flags.

    # Resolve sysroot relative to this script's location
    # On Redox: /nix/store/<hash>-redox-sysroot/bin/cc
    # Sysroot:  /nix/store/<hash>-redox-sysroot/sysroot/
    #
    # Since Ion doesn't support dirname/readlink easily, we use the
    # well-known store path symlink. The /nix/system/profile/sysroot/
    # directory exists because the build module creates it.
    let SYSROOT = "/usr/lib/redox-sysroot"

    # Check if this is a compile-only invocation
    let compile_only = false
    for arg in @args
      if test $arg = "-c"
        let compile_only = true
      else if test $arg = "-S"
        let compile_only = true
      else if test $arg = "-E"
        let compile_only = true
      else if test $arg = "-M"
        let compile_only = true
      else if test $arg = "-MM"
        let compile_only = true
      end
    end

    if test $compile_only = true
      # Compile-only: pass through with sysroot include paths
      exec clang -nostdlibinc -isystem $SYSROOT/include @args
    else
      # Link step: add CRT files, libc, and drive lld
      exec clang -static \
        $SYSROOT/lib/crt0.o $SYSROOT/lib/crti.o \
        @args \
        -L $SYSROOT/lib \
        -l:libc.a -l:libpthread.a \
        $SYSROOT/lib/crtn.o \
        -fuse-ld=lld
    end
    WRAPPER
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
