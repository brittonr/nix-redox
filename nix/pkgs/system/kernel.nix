# Redox Kernel - Microkernel (cross-compiled)
#
# Two-phase build for caching: dependency crates are compiled once and
# cached in a separate derivation (kernelDeps). When only kernel source
# changes, the final derivation reuses the cached deps and recompiles
# only the kernel crate (~3s instead of ~12s).
#
# Phase 1 (kernelDeps): stub main.rs → compile all 42 dependency crates
#   + build-std (core, alloc, compiler_builtins)
# Phase 2 (kernel): real source → cargo detects deps are fresh, compiles
#   only the kernel crate, then objcopy → kernel + kernel.sym

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  kernel-src,
  rmm-src,
  redox-path-src,
  fdt-src,
  vendor,
  ...
}:

let
  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  targetSpec = "targets/${targetArch}-unknown-kernel.json";

  # Prepare source with git submodules
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "kernel-src-patched";
    src = kernel-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    # Fix zeroed_phys_contiguous: initialize ALL 2^order frames and
    # use bulk deallocate_p2frame on free (prevents buddy allocator corruption)
    patches = [
      ./patches/kernel/patch-kernel-p2frame-init.patch
    ];

    nativeBuildInputs = [ pkgs.python3 ];

    postUnpack = ''
      rm -rf $sourceRoot/rmm
      cp -r ${rmm-src} $sourceRoot/rmm
      chmod -R u+w $sourceRoot/rmm

      rm -rf $sourceRoot/redox-path
      cp -r ${redox-path-src} $sourceRoot/redox-path
      chmod -R u+w $sourceRoot/redox-path
    '';

    postPatch = ''
      # Replace fdt git dependency with path (both Cargo.toml and Cargo.lock)
      if grep -q 'fdt = { git = "https://github.com/repnop/fdt.git"' Cargo.toml; then
        substituteInPlace Cargo.toml \
          --replace-fail 'fdt = { git = "https://github.com/repnop/fdt.git", rev = "2fb1409edd1877c714a0aa36b6a7c5351004be54" }' \
                         'fdt = { path = "${fdt-src}" }'
        # Also fix Cargo.lock so cargo doesn't need to re-lock at build time
        # (the "Locking 1 package" step modifies Cargo.lock, changing mtimes
        # and invalidating cargo fingerprints in the two-phase build)
        sed -i '/^name = "fdt"/,/^$/{/^source = "git+/d}' Cargo.lock
      fi

      # Restore ptrace proc: scheme handles (trace + mem)
      python3 ${./patches/kernel/patch-kernel-ptrace-proc-handles.py} .
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  kernelCargoArtifacts = craneLib.vendorCargoDeps {
    src = patchedSrc;
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "kernel";
    projectVendor = kernelCargoArtifacts;
    inherit sysrootVendor;
    useCrane = true;
  };

  commonNativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.nasm
    pkgs.llvmPackages.llvm
  ];

  commonEnv = {
    TARGET = redoxTarget;
    RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
  };

  # Configure phase shared by both derivations
  configureSource = src: ''
    cp -r ${src}/* .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    mkdir -p .cargo
    cat > .cargo/config.toml << 'EOF'
    ${vendor.mkCargoConfig { }}
  EOF

    # Use llvm-objcopy instead of target-prefixed objcopy
    sed -i 's/\$(GNU_TARGET)-objcopy/llvm-objcopy/g' Makefile
  '';

  # Target directory name cargo uses for this spec (stem of the JSON path)
  targetDirName = "${targetArch}-unknown-kernel";

  # Cargo command used by both phases (matches Makefile logic)
  cargoCmd = ''
    cargo rustc \
      --bin kernel \
      --manifest-path Cargo.toml \
      --target ${targetSpec} \
      --release \
      -Z build-std=core,alloc -Zbuild-std-features=compiler-builtins-mem \
      -- \
      -C link-arg=-T -Clink-arg=linkers/${targetArch}.ld \
      -C link-arg=-z -Clink-arg=max-page-size=0x1000 \
      --emit link=kernel.all
  '';

  # ── Phase 1: compile dependency crates with a stub kernel ──────────
  #
  # This derivation depends only on Cargo.toml, Cargo.lock, and the
  # vendored dependencies — NOT on the kernel source in src/. When
  # kernel source changes, this derivation is a cache hit.
  #
  # The stub main.rs is a minimal no_std binary that satisfies cargo
  # without pulling in any real kernel code. Cargo still compiles all
  # [dependencies] from Cargo.toml regardless of what the stub imports.
  kernelDeps = pkgs.stdenv.mkDerivation ({
    pname = "redox-kernel-deps";
    version = "unstable";

    dontUnpack = true;
    # Don't let fixup patch the build script ELF binaries — phase 2 needs
    # to re-run them from the copied target dir with matching fingerprints
    dontPatchELF = true;
    dontStrip = true;
    dontFixup = true;

    nativeBuildInputs = commonNativeBuildInputs;

    configurePhase = ''
      runHook preConfigure
      ${configureSource patchedSrc}

      # Replace kernel source with a stub — compiles all deps without
      # depending on the real src/ tree. Keep non-Rust files (asm, config)
      # because the build.rs needs them (nasm for trampoline.asm, config.toml).
      cat > src/main.rs << 'STUB'
      #![no_std]
      #![no_main]
      #[panic_handler]
      fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }
      STUB
      # Remove all other .rs files so they don't affect the dep hash
      find src -name '*.rs' ! -name 'main.rs' -delete

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      export HOME=$(mktemp -d)
      ${cargoCmd}
      runHook postBuild
    '';

    installPhase = ''
      # Save the cargo target directory — contains all compiled rlibs,
      # rmeta, build script outputs, and fingerprints for the deps
      mkdir -p $out
      cp -r target/. $out/
    '';
  } // commonEnv);

in
# ── Phase 2: compile only the kernel crate using cached deps ─────────
pkgs.stdenv.mkDerivation ({
  pname = "redox-kernel";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = commonNativeBuildInputs;

  configurePhase = ''
    runHook preConfigure
    ${configureSource patchedSrc}

    # Restore the cached dependency artifacts from phase 1
    cp -a ${kernelDeps}/. target/
    chmod -R u+w target/

    # Remove cargo lock files that can't be re-acquired across derivations
    find target -name '.cargo-lock' -delete
    find target -name '.package-cache' -delete

    # Reset all file timestamps in target/ to a consistent value.
    # Nix store normalizes mtimes to epoch (1), which breaks cargo's
    # mtime-based fingerprinting for build scripts. Setting everything
    # to "now" matches what cargo expects after a fresh build.
    find target -exec touch -d '2025-01-01T00:00:00' {} +

    # Invalidate the kernel crate fingerprints so cargo recompiles it
    # with the real source. All dependency fingerprints remain valid.
    rm -rf target/${targetDirName}/release/.fingerprint/kernel-*
    rm -rf target/${targetDirName}/release/deps/kernel-*

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    export HOME=$(mktemp -d)
    ${cargoCmd}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/boot

    # kernel.all is placed by --emit link=kernel.all
    llvm-objcopy --strip-debug kernel.all $out/boot/kernel
    llvm-objcopy --only-keep-debug kernel.all $out/boot/kernel.sym

    runHook postInstall
  '';

  passthru = {
    inherit patchedSrc kernelDeps;
    src = patchedSrc;
  };

  meta = with lib; {
    description = "Redox OS Kernel";
    homepage = "https://gitlab.redox-os.org/redox-os/kernel";
    license = licenses.mit;
  };
} // commonEnv)
