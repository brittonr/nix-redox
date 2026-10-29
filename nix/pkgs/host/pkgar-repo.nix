# pkgar-repo - Redox package repository server
#
# Builds and serves pkgar package repositories.
# Workspace member of the pkgar monorepo.
# Runs on the host (Linux), not on Redox.
#
# Dependencies: pkgar-keys, pkgar-core, ureq (rustls), thiserror
#
# Source: gitlab.redox-os.org/redox-os/pkgar (pkgar-repo/ subdirectory)

{ pkgs, lib, pkgar-src, ... }:

pkgs.rustPlatform.buildRustPackage {
  pname = "pkgar-repo";
  version = "0.2.4";
  src = pkgar-src;

  cargoHash = "sha256-QZssfZaaWTGm04pmRFi5ZCIEQiihmOBKOWyjW2fTyzw=";

  buildAndTestSubdir = "pkgar-repo";

  nativeBuildInputs = [ pkgs.perl ];

  # The upstream ring git source has no pregenerated assembly. Its build script
  # uses .git to select native source generation instead of release-tarball inputs.
  postPatch = ''
    mkdir "$cargoDepsCopy/source-git-0/ring-0.17.16000/.git"
  '';

  # pkgar-repo is a library crate — install the rlib
  postInstall = ''
    install -Dm644 "$releaseDir/libpkgar_repo.rlib" "$out/lib/libpkgar_repo.rlib"
  '';

  meta = with lib; {
    description = "Redox package repository library";
    homepage = "https://gitlab.redox-os.org/redox-os/pkgar";
    license = licenses.mit;
  };
}
