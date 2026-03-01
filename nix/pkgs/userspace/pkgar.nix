# pkgar - Package archive tool for Redox OS
#
# pkgar creates and extracts .pkgar package archives used by pkgutils.
# It handles signed, content-addressed package distribution.
#
# Source: gitlab.redox-os.org/redox-os/pkgar (Redox-native)
# Binary: pkgar (from pkgar workspace member with cli feature)

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  pkgar-src,
  ...
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      ;
  };

in
mkUserspace.mkPackage {
  pname = "pkgar";
  version = "0.2.0";
  src = pkgar-src;
  cargoBuildFlags = "--manifest-path pkgar/Cargo.toml --features cli";

  vendorHash = "sha256-QZssfZaaWTGm04pmRFi5ZCIEQiihmOBKOWyjW2fTyzw=";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/pkgar $out/bin/ 2>/dev/null || true
    runHook postInstall
  '';

  meta = with lib; {
    description = "Package archive tool for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/pkgar";
    license = licenses.mit;
    mainProgram = "pkgar";
  };
}
