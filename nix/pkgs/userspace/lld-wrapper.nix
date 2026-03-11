# lld-wrapper: Stack-growing launcher for ld.lld on Redox
#
# The Redox kernel gives the main thread ~8KB of stack, which isn't enough
# for lld's recursive symbol resolution and section layout. With JOBS>=2,
# concurrent linker invocations overflow and crash with:
#   fatal runtime error: failed to initiate panic, error 0, aborting
#
# Fix: spawn a thread with 16MB stack and exec() lld from it.
# Same pattern as patch-rustc-main-stack.py for rustc.
#
# Cross-compiled for Redox using rustc directly (no cargo needed for a
# single-file binary with no dependencies beyond std).

{
  pkgs,
  lib,
  rustToolchain,
  redoxTarget,
  relibc,
  stubLibs,
}:

let
  relibcDir = "${relibc}/${redoxTarget}";
  clangBin = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";

  src = pkgs.writeText "lld-wrapper-main.rs" ''
    use std::env;
    use std::os::unix::process::CommandExt;
    use std::process::Command;
    use std::thread;

    fn main() {
        let args: Vec<String> = env::args().skip(1).collect();
        let stack_size: usize = 16 * 1024 * 1024; // 16 MB

        match thread::Builder::new()
            .name("lld-main".into())
            .stack_size(stack_size)
            .spawn(move || {
                let lld = "/nix/system/profile/bin/ld.lld";
                let mut cmd = Command::new(lld);
                for arg in &args {
                    cmd.arg(arg);
                }
                let err = cmd.exec();
                eprintln!("lld-wrapper: failed to exec {}: {}", lld, err);
                std::process::exit(1);
            })
        {
            Ok(handle) => {
                let _ = handle.join();
                // exec() replaces the process, so we only reach here on failure
                std::process::exit(0);
            }
            Err(e) => {
                eprintln!("lld-wrapper: failed to create thread: {}", e);
                std::process::exit(1);
            }
        }
    }
  '';
in
pkgs.runCommand "lld-wrapper"
  {
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
      ${src} -o $out/bin/lld-wrapper
  ''
