let
  tools = import ./stage0-tools.nix;
in
derivation {
  name = "ripgrep-on-redox";
  system = "x86_64-unknown-redox";
  builder = "${tools.bash}/bin/bash";
  NIX_BASH = "${tools.bash}/bin/bash";
  NIX_RUSTC = "${tools.rustc}/bin/rustc";
  NIX_AR = "${tools.llvm}/bin/llvm-ar";
  NIX_CC = "${tools.sysroot}/bin/cc";
  NIX_TOOL_PATH = "${tools.sysroot}/bin:${tools.rustc}/bin:${tools.llvm}/bin:${tools.uutils}/bin:${tools.bash}/bin:/bin:/usr/bin";
  NIX_LD_LIBRARY_PATH = "${tools.rustc}/lib:${tools.llvm}/lib:/usr/lib/rustc:/lib";
  args = [ "--noprofile" "--norc" "/usr/src/ripgrep/build-ripgrep.sh" ];
}
