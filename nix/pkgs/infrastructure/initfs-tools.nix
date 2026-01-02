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

in
pkgs.stdenv.mkDerivation {
  pname = "redox-initfs-tools";
  version = "0.2.0";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.python3
  ];

  buildPhase = ''
    export HOME=$(mktemp -d)

    # Copy initfs source
    cp -r ${base-src}/initfs/* .
    chmod -R u+w .

    # Copy vendored deps (skip .cargo and Cargo.lock from fetchCargoVendor)
    mkdir -p vendor
    for crate in ${initfsToolsVendor}/*/; do
      crate_name=$(basename "$crate")
      if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
        continue
      fi
      cp -rL "$crate" "vendor/$crate_name"
    done
    chmod -R u+w vendor/

    # Regenerate checksums
    ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
    import json
    import hashlib
    from pathlib import Path

    vendor_dir = Path("vendor")
    for crate_dir in vendor_dir.iterdir():
        if not crate_dir.is_dir():
            continue
        checksum_file = crate_dir / ".cargo-checksum.json"
        if not checksum_file.exists():
            continue
        with open(checksum_file) as f:
            existing = json.load(f)
        pkg_hash = existing.get("package")
        files = {}
        for file_path in sorted(crate_dir.rglob("*")):
            if file_path.is_file() and file_path.name != ".cargo-checksum.json":
                rel_path = str(file_path.relative_to(crate_dir))
                with open(file_path, "rb") as f:
                    sha = hashlib.sha256(f.read()).hexdigest()
                files[rel_path] = sha
        new_data = {"files": files}
        if pkg_hash:
            new_data["package"] = pkg_hash
        with open(checksum_file, "w") as f:
            json.dump(new_data, f)
    PYTHON_CHECKSUM

    # Set up cargo config
    mkdir -p .cargo
    cat > .cargo/config.toml << 'EOF'
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "vendor"

    [net]
    offline = true
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
