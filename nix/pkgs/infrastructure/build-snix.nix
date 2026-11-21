# Nix derivation for self-compiling snix on Redox OS.
# Usage on guest: snix build --file /usr/src/snix-redox/build.nix
let
  tools = import ./stage0-tools.nix;
in
derivation {
  name = "snix-self-compiled";
  system = "x86_64-unknown-redox";
  builder = "${tools.bash}/bin/bash";
  NIX_BASH = "${tools.bash}/bin/bash";
  NIX_RUSTC = "${tools.rustc}/bin/rustc";
  NIX_AR = "${tools.llvm}/bin/llvm-ar";
  NIX_CC = "${tools.llvm}/bin/clang";
  NIX_TOOL_PATH = "${tools.rustc}/bin:${tools.llvm}/bin:${tools.uutils}/bin:${tools.bash}/bin:/bin:/usr/bin";
  NIX_LD_LIBRARY_PATH = "${tools.rustc}/lib:${tools.llvm}/lib:/usr/lib/rustc:/lib";
  NIX_SYSROOT = "${tools.sysroot}";
  args = [ "/usr/src/snix-redox/build-snix.sh" ];
}
