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
        outputHash = "sha256-oTnMDWezAi9VP+Wd9PxqWkyHpCr+jwB+Wpon8UdEWMk=";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      }
      ''
        export HOME=$(mktemp -d)
        mkdir -p $out
        # Copy entire initfs directory to include archive-common
        cp -r ${base-src}/initfs/* $out/
        chmod -R u+w $out

        # Replace workspace-inherited dependencies with explicit versions.
        # These values come from the base root Cargo.toml [workspace.dependencies].
        find $out -name Cargo.toml -exec sed -i \
          -e 's/anyhow.workspace = true/anyhow = "1"/g' \
          -e 's/log.workspace = true/log = "0.4"/g' \
          {} +

        cd $out/tools
        cargo generate-lockfile
      '';

  # Vendor dependencies using fetchCargoVendor (FOD)
  initfsToolsVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "initfs-tools-vendor";
    src = initfsToolsSrc;
    sourceRoot = "initfs-tools-src/tools";
    hash = "sha256-ygduJkCd7Iizz1fP0ZOXvTiQbnIhGoFYzOyeLKmGBlg=";
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

    # Copy initfs source
    cp -r ${base-src}/initfs/* .
    chmod -R u+w .

    # Replace workspace-inherited dependencies with explicit versions
    find . -name Cargo.toml -exec sed -i \
      -e 's/anyhow.workspace = true/anyhow = "1"/g' \
      -e 's/log.workspace = true/log = "0.4"/g' \
      {} +

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    # Set up cargo config
    mkdir -p .cargo
    cat > .cargo/config.toml << 'EOF'
    ${vendor.mkCargoConfig { }}
    EOF

    # Ensure tools directory exists and is writable before copying lockfile
    mkdir -p tools
    chmod -R u+w tools

    # Copy lockfile from the initfsToolsSrc which has the generated lock
    cp ${initfsToolsSrc}/tools/Cargo.lock tools/
    # Make the lockfile writable so cargo can update it if needed
    chmod u+w tools/Cargo.lock

    # Build tools
    cargo build --manifest-path tools/Cargo.toml --release

    runHook postBuild
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
