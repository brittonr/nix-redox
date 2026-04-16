# Compiled CC launcher for Redox self-hosting
#
# rustc spawning a shell-script linker through the proxy sandbox can fail with:
#   could not exec the linker `/nix/system/profile/bin/cc`
#   File exists (os error 17)
#
# Keep the full bash helper logic in redox-sysroot.nix, but make the public
# `/nix/system/profile/bin/cc` entrypoint an ELF binary. That way rustc/cc-rs
# exec a normal binary, which then execs bash with the helper script path.

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

  src = pkgs.writeText "cc-wrapper-main.rs" ''
    use std::env;
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    fn main() {
        let bash = env::var("PI_CC_WRAPPER_BASH")
            .unwrap_or_else(|_| "/nix/system/profile/bin/bash".to_string());
        let helper = env::var("PI_CC_WRAPPER_SCRIPT")
            .unwrap_or_else(|_| "/nix/system/profile/bin/cc-helper".to_string());

        let mut cmd = Command::new(&bash);
        cmd.env("LD_LIBRARY_PATH", "/nix/system/profile/lib:/usr/lib/rustc:/lib");
        cmd.arg(&helper);
        for arg in env::args().skip(1) {
            cmd.arg(arg);
        }

        let err = cmd.exec();
        eprintln!(
            "cc-wrapper: failed to exec {} {}: {}",
            bash, helper, err
        );
        std::process::exit(1);
    }
  '';
in
pkgs.runCommand "cc-wrapper-redox"
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
      ${src} -o $out/bin/cc-wrapper
  ''
