# initfs-tools - Host tools for creating initfs images
#
# These tools run on the build machine to create the initial RAM filesystem.
# - redox-initfs-ar: Creates initfs archive from directory
# - redox-initfs-dump: Dumps/inspects initfs archives

{
  pkgs,
  lib,
  rustToolchain,
  base-src,
  vendor,
}:

let
  # Extract initfs tools source with generated Cargo.lock (FOD)
  #
  # The upstream initfs crates now use workspace-inherited dependencies
  # (anyhow.workspace = true, log.workspace = true) from the base root
  # Cargo.toml. Since we only copy the initfs/ subdirectory, we need to
  # replace these with explicit versions.
  initfsToolsSrc =
    pkgs.runCommand "initfs-tools-src"
      {
        nativeBuildInputs = [
          rustToolchain
          pkgs.cacert
        ];
        # FOD for generating Cargo.lock
        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
        outputHash = "sha256-OgFNJIrLsl5TwfccqbsZmLIZB4vNyHkl2wHfRsf3doU=";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      }
      ''
        export HOME=$(mktemp -d)
        mkdir -p $out/initfs
        # Copy entire initfs directory to include archive-common
        cp -r ${base-src}/initfs/. $out/initfs/
        chmod -R u+w $out

        # Create a workspace root with the dependency versions that
        # initfs/ and initfs/tools/ inherit via workspace = true.
        # These values come from the base root Cargo.toml [workspace.dependencies].
        cat > $out/Cargo.toml << 'WORKSPACE'
        [workspace]
        resolver = "2"
        members = ["initfs", "initfs/tools"]

        [workspace.dependencies]
        anyhow = "1"
        clap = "4"
        log = "0.4"
        plain = "0.2.3"

        [workspace.lints.rust]

        [workspace.lints.clippy]
        WORKSPACE

        cd $out/initfs/tools
        cargo generate-lockfile
      '';

  # Vendor dependencies using fetchCargoVendor (FOD)
  initfsToolsVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "initfs-tools-vendor";
    src = initfsToolsSrc;
    hash = "sha256-v2EZBo3v2Cfkblt+1erADvldConjCxCJvYDgxHY2CmA=";
  };

  # Create vendor directory (no sysroot merge needed for host tools)
  mergedVendor = vendor.mkMergedVendor {
    name = "initfs-tools";
    projectVendor = initfsToolsVendor;
    # sysrootVendor not needed for host tools
  };

in
pkgs.stdenv.mkDerivation {
  pname = "redox-initfs-tools";
  version = "0.2.0";

  dontUnpack = true;

  # Disable automatic cargo build phase
  dontBuild = false;

  nativeBuildInputs = [
    rustToolchain
  ];

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    # Copy workspace source from initfsToolsSrc (has workspace root + generated lockfile)
    cp -r ${initfsToolsSrc}/. .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    # Set up cargo config
    mkdir -p .cargo
    cat > .cargo/config.toml << 'EOF'
    ${vendor.mkCargoConfig { }}
  EOF

    # Build tools
    cargo build --manifest-path initfs/tools/Cargo.toml --release

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp target/release/redox-initfs-ar $out/bin/
    cp target/release/redox-initfs-dump $out/bin/
  '';

  meta = with lib; {
    description = "Redox initfs archive tools";
    homepage = "https://gitlab.redox-os.org/redox-os/base";
    license = licenses.mit;
  };
}
