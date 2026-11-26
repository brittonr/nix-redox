# Nix derivation for rebuilding the Redox kernel on a running Redox guest.
# Usage on guest: snix build --file /usr/src/native-kernel-rebuild/kernel/build.nix

let
  tools = import ../stage0-tools.nix;
in
derivation {
  name = "redox-kernel-native-rebuild";
  system = "x86_64-unknown-redox";
  builder = "${tools.bash}/bin/bash";
  NIX_BASH = "${tools.bash}/bin/bash";
  NIX_RUSTC = "${tools.rustc}/bin/rustc";
  NIX_AR = "${tools.llvm}/bin/llvm-ar";
  NIX_CC = "${tools.sysroot}/bin/cc";
  NIX_NASM = "${tools.nasm}/bin/nasm";
  NIX_LLD_WRAPPER = "${tools.lldWrapper}/bin/lld-wrapper";
  NIX_OBJCOPY = "${tools.llvm}/bin/llvm-objcopy";
  NIX_SYSROOT = "${tools.sysroot}";
  NIX_TOOL_PATH = "${tools.rustc}/bin:${tools.llvm}/bin:${tools.uutils}/bin:${tools.bash}/bin:/bin:/usr/bin";
  NIX_LD_LIBRARY_PATH = "${tools.rustc}/lib:${tools.llvm}/lib:/usr/lib/rustc:/lib";
  args = [ "--noprofile" "--norc" "${./.}/build-redox-kernel.sh" ];
  source = ./.;
  rustSource = ../rust-src;
  bootstrapInputs = builtins.readFile ../bundle-manifest.json;
}
