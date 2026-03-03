# libstdc++.so.6 shim for Redox — provides C++ runtime symbols
#
# librustc_driver.so has NEEDED: libstdc++.so.6 because the Rust build system
# links with -lstdc++. We use LLVM's libc++ (statically linked into LLVM code),
# but the dynamic linker still needs to resolve this shared library at runtime.
#
# This package creates a shared libstdc++.so.6 from our static libc++ archives
# (libc++.a + libc++abi.a + libunwind.a), providing all C++ ABI symbols
# (__cxa_guard_*, operator new/delete, exception handling, etc.).
#
# Output: libstdc++.so.6 (~3 MB shared ELF for x86_64-unknown-redox)

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-libcxx,
  ...
}:

pkgs.stdenv.mkDerivation {
  pname = "libstdcxx-redox-shim";
  version = "1.0.0";

  nativeBuildInputs = [
    pkgs.llvmPackages.lld
    pkgs.patchelf
  ];

  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    echo "Building libstdc++.so.6 from static libc++ archives..."

    # Combine libc++.a + libc++abi.a + libunwind.a into a single shared library.
    # --whole-archive ensures ALL symbols are exported (not just referenced ones).
    ${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
      --target=${redoxTarget} \
      --sysroot=${relibc}/sysroot \
      -shared -o libstdc++.so.6 \
      -fuse-ld=lld -nostdlib \
      -Wl,--whole-archive \
        ${redox-libcxx}/lib/libc++.a \
        ${redox-libcxx}/lib/libc++abi.a \
        ${redox-libcxx}/lib/libunwind.a \
      -Wl,--no-whole-archive \
      -Wl,-soname,libstdc++.so.6

    # Replace Linux-specific NEEDED entries with Redox's libc.so
    # Linux: librt.so.1, libpthread.so.0, libdl.so.2 → Redox: all in libc.so
    patchelf --remove-needed librt.so.1 libstdc++.so.6 || true
    patchelf --remove-needed libpthread.so.0 libstdc++.so.6 || true
    patchelf --remove-needed libdl.so.2 libstdc++.so.6 || true
    patchelf --remove-needed libc.so.6 libstdc++.so.6 || true
    patchelf --add-needed libc.so libstdc++.so.6

    echo "Built libstdc++.so.6 ($(wc -c < libstdc++.so.6) bytes)"
    echo "NEEDED entries: $(readelf -d libstdc++.so.6 | grep NEEDED | wc -l)"
    echo "Exported symbols: $(${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-nm -D libstdc++.so.6 | grep -c ' T ')"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib
    cp libstdc++.so.6 $out/lib/

    runHook postInstall
  '';

  meta = {
    description = "libstdc++.so.6 shim (libc++ as shared lib) for Redox";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
