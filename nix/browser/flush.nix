# Dependency-free guest fsync executable. Uses the established standalone Rust
# cross-link convention from pkgs/userspace/cc-wrapper-redox.nix.
{
  pkgs,
  rustToolchain,
  redoxTarget,
  relibc,
  stubLibs,
}:
let
  relibcDir = "${relibc}/${redoxTarget}";
  clangBin = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
in
pkgs.runCommand "browser-demo-flush-1"
  {
    pname = "browser-demo-flush";
    version = "1";
    nativeBuildInputs = [
      rustToolchain
      pkgs.llvmPackages.clang
      pkgs.llvmPackages.lld
    ];
  }
  ''
    mkdir -p $out/bin
    rustc --target ${redoxTarget} \
      --edition 2021 \
      -C panic=abort \
      -C opt-level=2 \
      -C target-cpu=x86-64 \
      -C linker=${clangBin} \
      -C link-arg=-nostdlib \
      -C link-arg=-static \
      -C link-arg=--target=${redoxTarget} \
      -C link-arg=${relibcDir}/lib/crt0.o \
      -C link-arg=${relibcDir}/lib/crti.o \
      -C link-arg=${relibcDir}/lib/crtn.o \
      -C link-arg=-Wl,--allow-multiple-definition \
      -L ${relibcDir}/lib \
      -L ${stubLibs}/lib \
      ${./flush.rs} -o $out/bin/browser-demo-flush
  ''
