# Installer - Redox filesystem builder (host tool)
#
# Creates Redox filesystem images from directory trees.
# Runs on the host machine (not cross-compiled).
#
# Note: Uses ring from crates.io instead of git to get pregenerated assembly.

{
  pkgs,
  lib,
  rustToolchain,
  src,
  ...
}:

let
  # Fetch ring 0.17.8 from crates.io with pregenerated assembly files
  ringCrate = pkgs.fetchurl {
    url = "https://crates.io/api/v1/crates/ring/0.17.8/download";
    sha256 = "sha256-wX+ky2WONYNCPpFbnzrMAczq7hhg4z1Z665mrcOi3A0=";
  };

  # Patch source to use local ring instead of git
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "installer-src-patched";
    inherit src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    patchPhase = ''
      runHook prePatch

      # Extract ring crate from crates.io (has pregenerated assembly files)
      mkdir -p deps
      tar -xzf ${ringCrate} -C deps
      mv deps/ring-0.17.8 deps/ring

      # Replace the git URL in [patch.crates-io] with a local path
      sed -i 's|ring = { git = "https://gitlab.redox-os.org/redox-os/ring.git", branch = "redox-0.17.8" }|ring = { path = "deps/ring" }|' Cargo.toml

      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor dependencies
  installerVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "installer-cargo-vendor";
    src = patchedSrc;
    hash = "sha256-RMxyZ/isSvgxEtRompst/F6ZavAMbHBYMB/G8H4Wk5A=";
  };

in
pkgs.stdenv.mkDerivation {
  pname = "redox-installer";
  version = "unstable";

  src = patchedSrc;

  nativeBuildInputs = [
    rustToolchain
    pkgs.pkg-config
  ];

  buildInputs = with pkgs; [
    fuse
    fuse3
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p .cargo
    cat > .cargo/config.toml << EOF
    [source.crates-io]
    replace-with = "vendored"

    [source.vendored]
    directory = "${installerVendor}"

    [net]
    offline = true
    EOF

    export HOME=$(mktemp -d)

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    cargo build --release

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp target/release/redox_installer $out/bin/
    cp target/release/redox_installer_tui $out/bin/ 2>/dev/null || true

    runHook postInstall
  '';

  doCheck = false;

  meta = with lib; {
    description = "Redox OS Installer - filesystem image builder";
    longDescription = ''
      The Redox installer creates RedoxFS filesystem images from directory trees.
      It is used during the build process to create bootable Redox images.
    '';
    homepage = "https://gitlab.redox-os.org/redox-os/installer";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "redox_installer";
  };
}
