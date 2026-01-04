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

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "bootstrap";
    projectVendor = bootstrapVendor;
    inherit sysrootVendor;
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

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} $BOOTSTRAP_DIR/vendor-combined
    chmod -R u+w $BOOTSTRAP_DIR/vendor-combined

    cd $BOOTSTRAP_DIR
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
