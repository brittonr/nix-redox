# pkgar-repo - Redox package repository server
#
# Builds and serves pkgar package repositories.
# Workspace member of the pkgar monorepo.
# Runs on the host (Linux), not on Redox.
#
# Dependencies: pkgar, pkgar-core, reqwest (blocking + rustls-tls)
#
# Source: gitlab.redox-os.org/redox-os/pkgar (pkgar-repo/ subdirectory)

{ pkgs, lib, pkgar-src, ... }:

pkgs.rustPlatform.buildRustPackage {
  pname = "pkgar-repo";
  version = "0.2.1";
  src = pkgar-src;

  cargoHash = "sha256-QZssfZaaWTGm04pmRFi5ZCIEQiihmOBKOWyjW2fTyzw=";

  buildAndTestSubdir = "pkgar-repo";

  # pkgar-repo is a library crate — install the rlib
  postInstall = ''
    mkdir -p $out/lib
    find target/release -maxdepth 1 \( -name "*.rlib" -o -name "*.a" \) \
      -exec cp {} $out/lib/ \; 2>/dev/null || true
  '';

  meta = with lib; {
    description = "Redox package repository library";
    homepage = "https://gitlab.redox-os.org/redox-os/pkgar";
    license = licenses.mit;
  };
}
