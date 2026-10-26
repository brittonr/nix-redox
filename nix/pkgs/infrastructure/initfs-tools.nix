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
  # Extract initfs tools source with the pre-generated Cargo.lock
  #
  # The upstream initfs crates now use workspace-inherited dependencies
  # (anyhow.workspace = true, log.workspace = true) from the base root
  # Cargo.toml. Since we only copy the initfs/ subdirectory, we need to
  # provide a workspace root with explicit versions.
  #
  # == Lockfile Regeneration ==
  # Never resolve the lockfile at build time: `cargo generate-lockfile`
  # picks the newest semver-compatible crates on every run, so the fixed
  # output hash changes whenever crates.io publishes (and the build needs
  # network). The lockfile is committed instead, like bootstrap-Cargo.lock.
  # Regenerate when base-src initfs manifests change (e.g. `nix flake update`):
  #   1. In a temp dir, copy base-src/initfs/ and write the workspace root
  #      Cargo.toml below at the workspace root.
  #   2. Run `cargo generate-lockfile` from initfs/tools.
  #   3. Copy the resulting lockfile to
  #      nix/pkgs/infrastructure/initfs-tools-Cargo.lock.
  #   4. Update the vendor hash below (set dummy, build, read the real hash
  #      from the mismatch error), then `git add` the lockfile.
  initfsToolsSrc = pkgs.runCommand "initfs-tools-src" { } ''
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

        # Committed lockfile: no dependency resolution (or network) at build time.
        cp ${./initfs-tools-Cargo.lock} $out/Cargo.lock

        # The release default caps the image at 64 MiB, which the graphical
        # profile now exceeds (~67 MiB with drivers in both bin/ and
        # lib/drivers/). Raise the cap to 256 MiB (the debug default).
        sed -i 's/pub const DEFAULT_MAX_SIZE: u64 = 64 \* MEBIBYTE;/pub const DEFAULT_MAX_SIZE: u64 = 256 * MEBIBYTE;/' \
          $out/initfs/tools/src/lib.rs
      '';

  # Vendor dependencies using fetchCargoVendor (FOD)
  initfsToolsVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "initfs-tools-vendor";
    src = initfsToolsSrc;
    hash = "sha256-1yqEF2K1GXx3upOgf1VXa/hwFWVlrwCd3liHGZwlZ+k=";
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

  # The guest-native recipe consumes the same source, lockfile and vendor tree.
  passthru = { inherit initfsToolsSrc mergedVendor; };

  meta = with lib; {
    description = "Redox initfs archive tools";
    homepage = "https://gitlab.redox-os.org/redox-os/base";
    license = licenses.mit;
  };
}
