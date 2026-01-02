# Bootstrap - Minimal loader for initfs
#
# The bootstrap loader is the first program that runs in the initfs.
# It's built as a staticlib and linked with a custom linker script
# to create an ELF binary that can be prepended to the initfs archive.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  base-src,
  relibc-src,
  vendor,
}:

let
  # Prepare source with patches
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "bootstrap-src-patched";
    src = base-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    patchPhase = ''
      runHook prePatch

      # Patch redox-rt git dependency to use our relibc source
      substituteInPlace bootstrap/Cargo.toml \
        --replace-quiet 'redox-rt = { git = "https://gitlab.redox-os.org/redox-os/relibc.git", default-features = false }' \
                       'redox-rt = { path = "${relibc-src}/redox-rt", default-features = false }'

      # Fix linker script for page alignment (mprotect requires aligned addresses)
      cat > bootstrap/src/x86_64.ld << 'LINKERSCRIPT'
      ENTRY(_start)
      OUTPUT_FORMAT(elf64-x86-64)

      SECTIONS {
        . = 4096 + 4096; /* Reserved for null page and initfs header */
        __initfs_header = . - 4096;
        . += SIZEOF_HEADERS;
        . = ALIGN(4096);

        .text : {
          __text_start = .;
          *(.text*)
          . = ALIGN(4096);
          __text_end = .;
        }

        . = ALIGN(4096);
        .rodata : {
          __rodata_start = .;
          *(.rodata*)
          *(.interp*)
          . = ALIGN(4096);
          __rodata_end = .;
        }

        . = ALIGN(4096);
        .data : {
          __data_start = .;
          *(.got*)
          *(.data*)
          . = ALIGN(4096);

          *(.tbss*)
          . = ALIGN(4096);
          *(.tdata*)
          . = ALIGN(4096);

          __bss_start = .;
          *(.bss*)
          . = ALIGN(4096);
          __bss_end = .;
        }

        /DISCARD/ : {
            *(.comment*)
            *(.eh_frame*)
            *(.gcc_except_table*)
            *(.note*)
            *(.rel.eh_frame*)
        }
      }
      LINKERSCRIPT

      runHook postPatch
    '';

    installPhase = ''
      mkdir -p $out
      cp -r bootstrap $out/
      cp -r initfs $out/
    '';
  };

  # Vendor dependencies using fetchCargoVendor (FOD)
  bootstrapVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "bootstrap-cargo-vendor";
    src = patchedSrc;
    sourceRoot = "bootstrap-src-patched/bootstrap";
    hash = "sha256-mZ2joQC+831fSEfWAtH4paQJp28MMHnb61KuTYsGV/A=";
  };

in
pkgs.stdenv.mkDerivation {
  pname = "redox-bootstrap";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
    pkgs.python3
  ];

  TARGET = redoxTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
    runHook preConfigure

    export BUILD_ROOT=$PWD
    export BOOTSTRAP_DIR=$BUILD_ROOT/workspace/bootstrap
    export INITFS_DIR=$BUILD_ROOT/workspace/initfs

    # Create workspace layout
    mkdir -p $BOOTSTRAP_DIR $INITFS_DIR
    cp -r ${patchedSrc}/bootstrap/* $BOOTSTRAP_DIR/
    cp -r ${patchedSrc}/initfs/* $INITFS_DIR/
    chmod -R u+w $PWD/workspace

    # Version-aware vendor merge
    mkdir -p $BOOTSTRAP_DIR/vendor-combined

    get_version() {
      grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
    }

    for crate in ${bootstrapVendor}/*/; do
      crate_name=$(basename "$crate")
      if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
        continue
      fi
      cp -rL "$crate" "$BOOTSTRAP_DIR/vendor-combined/$crate_name"
    done
    chmod -R u+w $BOOTSTRAP_DIR/vendor-combined/

    for crate in ${sysrootVendor}/*/; do
      crate_name=$(basename "$crate")
      if [ ! -d "$crate" ]; then
        continue
      fi
      if [ -d "$BOOTSTRAP_DIR/vendor-combined/$crate_name" ]; then
        base_version=$(get_version "$BOOTSTRAP_DIR/vendor-combined/$crate_name")
        sysroot_version=$(get_version "$crate")
        if [ "$base_version" != "$sysroot_version" ]; then
          versioned_name="$crate_name-$sysroot_version"
          if [ ! -d "$BOOTSTRAP_DIR/vendor-combined/$versioned_name" ]; then
            cp -rL "$crate" "$BOOTSTRAP_DIR/vendor-combined/$versioned_name"
          fi
        fi
      else
        cp -rL "$crate" "$BOOTSTRAP_DIR/vendor-combined/$crate_name"
      fi
    done
    chmod -R u+w $BOOTSTRAP_DIR/vendor-combined/

    # Regenerate checksums
    cd $BOOTSTRAP_DIR
    ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
    ${vendor.checksumScript}
    PYTHON_CHECKSUM

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "vendor-combined"

    [net]
    offline = true

    [build]
    target = "${redoxTarget}"

    [profile.release]
    panic = "abort"
    lto = "fat"
    CARGOCONF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    cd $BOOTSTRAP_DIR

    # Build bootstrap as staticlib
    RUSTFLAGS="-Ctarget-feature=+crt-static" cargo \
      -Z build-std=core,alloc,compiler_builtins \
      -Z build-std-features=compiler-builtins-mem \
      build \
      --target ${redoxTarget} \
      --release

    # Link with custom linker script
    ld.lld \
      -o bootstrap \
      --gc-sections \
      -T src/x86_64.ld \
      -z max-page-size=4096 \
      target/${redoxTarget}/release/libbootstrap.a

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $BOOTSTRAP_DIR/bootstrap $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Redox bootstrap loader";
    license = licenses.mit;
  };
}
