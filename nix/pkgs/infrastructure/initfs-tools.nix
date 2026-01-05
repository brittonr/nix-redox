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
        outputHash = "sha256-R2SrraRIDoyg55376QwkSnR7Cn4BclFUzj4sKUuCbtc=";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      }
      ''
        export HOME=$(mktemp -d)
        mkdir -p $out
        # Copy entire initfs directory to include archive-common
        cp -r ${base-src}/initfs/* $out/
        chmod -R u+w $out
        cd $out/tools
        cargo generate-lockfile
      '';

  # Vendor dependencies using fetchCargoVendor (FOD)
  initfsToolsVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "initfs-tools-vendor";
    src = initfsToolsSrc;
    sourceRoot = "initfs-tools-src/tools";
    hash = "sha256-MHt/Nh/2TEy3W55OVYsLGBGUxhpvzKOSHk6kqMkpA2s=";
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

  nativeBuildInputs = [
    rustToolchain
  ];

  buildPhase = ''
    export HOME=$(mktemp -d)

    # Copy initfs source
    cp -r ${base-src}/initfs/* .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    # Set up cargo config
    mkdir -p .cargo
    cat > .cargo/config.toml << 'EOF'
    ${vendor.mkCargoConfig { }}
    EOF

    # Copy lockfile from the initfsToolsSrc which has the generated lock
    cp ${initfsToolsSrc}/tools/Cargo.lock tools/

    # Build tools
    cargo build --manifest-path tools/Cargo.toml --release
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp tools/target/release/redox-initfs-ar $out/bin/
    cp tools/target/release/redox-initfs-dump $out/bin/
  '';

  meta = with lib; {
    description = "Redox initfs archive tools";
    homepage = "https://gitlab.redox-os.org/redox-os/base";
    license = licenses.mit;
  };
}
