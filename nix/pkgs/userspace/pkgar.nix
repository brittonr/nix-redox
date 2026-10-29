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
  version = "0.2.4";
  src = pkgar-src;
  cargoBuildFlags = "--manifest-path pkgar/Cargo.toml --features cli";

  vendorHash = "sha256-QZssfZaaWTGm04pmRFi5ZCIEQiihmOBKOWyjW2fTyzw=";

  nativeBuildInputs = [ pkgs.perl ];

  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/ring.git?branch=redox-0.17.16";
      git = "https://gitlab.redox-os.org/redox-os/ring.git";
      branch = "redox-0.17.16";
    }
  ];

  # The git fork ships Perl sources, not pregenerated assembly. Restore the
  # marker used by ring's build script after cargo vendor drops it.
  postConfigure = ''
    find vendor-combined -maxdepth 1 -name 'ring-*' -type d \
      -exec mkdir -p '{}/.git' \;
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/pkgar $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Package archive tool for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/pkgar";
    license = licenses.mit;
    mainProgram = "pkgar";
  };
}
