# Resolve the seed's native build tools by manifest package name.
#
# The result is rendered into guest-visible bundles as stage0-tools.nix so
# recipes can name their tools as store paths instead of the mutable profile.
{ seedPackages }:
let
  tool = name:
    let matches = builtins.filter (p: p.name == name) seedPackages; in
    if matches == [ ] then
      throw "native bundle: seed has no package '${name}'"
    else
      (builtins.head matches).storePath;
in
{
  bash = tool "redox-bash";
  uutils = tool "redox-uutils";
  rustc = tool "rustc-redox";
  llvm = tool "llvm-redox";
  lldWrapper = tool "lld-wrapper";
  make = tool "gnu-make";
  nasm = tool "redox-nasm";
  sysroot = tool "redox-sysroot";
}
