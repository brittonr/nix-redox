# Orbital - Display Server and Window Manager for Redox OS
#
# Orbital is the graphical display server for Redox OS, providing:
# - Window management and compositing
# - Input handling (via inputd)
# - Graphics IPC for applications
#
# Dependencies: The vendoring approach creates a synthetic deps package that includes
# all transitive dependencies including those from graphics-ipc and inputd.
#
# Key deps from upstream:
# - redox-scheme = "0.6", redox_syscall = "0.5", libredox = "0.1.3"
# - orbclient, orbfont, orbimage (crates.io versions)
# - graphics-ipc, inputd (from base subdirectories)

{
  pkgs,
  lib,
  craneLib ? null, # Not used currently
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  orbital-src,
  # Upstream base crates orbital depends on (graphics-ipc, inputd, daemon),
  # pinned to the base rev orbital's Cargo.lock references.
  base-orbital-src,
  # Optional/unused inputs accepted for compatibility
  orbclient-src ? null,
  orbfont-src ? null,
  orbimage-src ? null,
  libredox-src ? null,
  liblibc-src ? null,
  rustix-redox-src,
  drm-rs-src,
  redox-log-src ? null,
  relibc-src ? null,
  redox-syscall-src ? null,
  redox-scheme-src ? null,
  ...
}:

let
  # Import centralized rust-flags (derived from target, not hardcoded)
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  # Workspace root fragment for the copied base crates. They inherit
  # dependencies and lints from base's workspace root, which we do not copy;
  # orbital's package root becomes the workspace root. Versions mirror
  # base/Cargo.toml [workspace.dependencies].
  workspaceToml = pkgs.writeText "orbital-workspace.toml" ''
    [workspace]
    resolver = "2"
    members = [
      "base/daemon",
      "base/scheme-utils",
      "base/drivers/common",
      "base/drivers/inputd",
      "base/drivers/graphics/graphics-ipc",
    ]

    [workspace.dependencies]
    anyhow = "1"
    drm = "0.15.0"
    libc = "=0.2.181"
    libredox = "=0.1.16"
    log = "0.4"
    orbclient = "=0.3.54"
    redox-log = { path = "${redox-log-src}" }
    redox-scheme = "=0.11.0"
    redox_syscall = { version = "=0.7.5", features = ["std"] }

    [workspace.lints.rust]
    missing_docs = "allow"

    [workspace.lints.clippy]
    precedence = "deny"
  '';

  # Create patched source with all path dependencies resolved
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "orbital-src-patched-v10"; # v10: track current base graphics-ipc API + committed Cargo.lock
    src = orbital-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    nativeBuildInputs = [ pkgs.python3 ];

    patchPhase = ''
            runHook prePatch

            # Create local copies of the base crates orbital depends on.
            mkdir -p base/drivers/graphics
            cp -r ${base-orbital-src}/drivers/inputd base/drivers/
            cp -r ${base-orbital-src}/drivers/graphics/graphics-ipc base/drivers/graphics/
            cp -r ${base-orbital-src}/drivers/common base/drivers/
            # inputd depends on daemon and scheme-utils
            cp -r ${base-orbital-src}/daemon base/
            cp -r ${base-orbital-src}/scheme-utils base/

            chmod -R u+w base/

            # Make orbital's package root the workspace root for the copied base
            # crates, which inherit dependencies and lints from base.
            cat >> Cargo.toml ${workspaceToml}

            # Patch orbital Cargo.toml to use local paths for git deps
            substituteInPlace Cargo.toml \
              --replace-quiet 'inputd = { git = "https://gitlab.redox-os.org/redox-os/base.git" }' \
                             'inputd = { path = "base/drivers/inputd" }' \
              --replace-quiet 'graphics-ipc = { git = "https://gitlab.redox-os.org/redox-os/base.git" }' \
                             'graphics-ipc = { path = "base/drivers/graphics/graphics-ipc" }'

            # Patch [patch.crates-io] git deps to use local paths
            substituteInPlace Cargo.toml \
              --replace-quiet 'drm = { git = "https://github.com/Smithay/drm-rs.git" }' \
                             'drm = { path = "${drm-rs-src}" }' \
              --replace-quiet 'drm-sys = { git = "https://github.com/Smithay/drm-rs.git" }' \
                             'drm-sys = { path = "${drm-rs-src}/drm-ffi/drm-sys" }' \
              --replace-quiet 'rustix = { git = "https://github.com/jackpot51/rustix.git", branch = "redox-ioctl" }' \
                             'rustix = { path = "${rustix-redox-src}" }' \
              --replace-quiet 'redox-log = { git = "https://gitlab.redox-os.org/redox-os/redox-log.git" }' \
                             'redox-log = { path = "${redox-log-src}" }'

            # Remove orbclient git override from [patch.crates-io] since the git version
            # and crates.io version now have the same version number (0.3.50), causing
            # conflicts in the vendor directory. The crates.io version works fine.
            sed -i '/orbclient = { git = "https:\/\/gitlab.redox-os.org\/redox-os\/orbclient.git"/d' Cargo.toml

            # Also remove relibc git override from [patch.crates-io] if present
            sed -i '/^relibc = { git = /d' Cargo.toml

            # drm 0.15 pulls rustix from crates.io, whose libc backend does not
            # handle relibc's 64-bit dev_t on Redox. Upstream orbital no longer
            # carries the rustix patch itself, so add it to its [patch.crates-io].
            sed -i '/^\[patch.crates-io\]$/a rustix = { path = "${rustix-redox-src}" }' Cargo.toml

            # The committed lockfile replaces upstream's, which still points at
            # git sources for the crates we now consume as local paths.
            cp ${./orbital-Cargo.lock} Cargo.lock

            # Fix ImageAligned to use manual page alignment instead of libc::memalign
            # The libc::memalign in relibc may not properly page-align allocations,
            # causing EINVAL when the kernel validates mmap_prep responses.
            # This is the same issue we fixed in vesad's GraphicScreen.
            if [ -f src/core/image.rs ]; then
              echo "Patching ImageAligned for page-aligned allocation..."
              python3 - src/core/image.rs << 'PATCH_EOF'
    import sys

    file_path = sys.argv[1]
    with open(file_path, 'r') as f:
        content = f.read()

    # Find and replace the ImageAligned struct and its impl
    old_struct = """pub struct ImageAligned {
        w: i32,
        h: i32,
        data: &'static mut [Color],
    }"""

    new_struct = """pub struct ImageAligned {
        w: i32,
        h: i32,
        data: &'static mut [Color],
        // Original allocation pointer for proper deallocation
        alloc_ptr: *mut u8,
        alloc_size: usize,
    }"""

    if old_struct in content:
        content = content.replace(old_struct, new_struct)
        print("Replaced ImageAligned struct")
    else:
        print("WARNING: Could not find ImageAligned struct")

    # Replace Drop impl
    old_drop = """impl Drop for ImageAligned {
        fn drop(&mut self) {
            unsafe {
                libc::free(self.data.as_mut_ptr() as *mut libc::c_void);
            }
        }
    }"""

    new_drop = """impl Drop for ImageAligned {
        fn drop(&mut self) {
            unsafe {
                // Use the original allocation pointer for deallocation
                libc::free(self.alloc_ptr as *mut libc::c_void);
            }
        }
    }"""

    if old_drop in content:
        content = content.replace(old_drop, new_drop)
        print("Replaced Drop impl")
    else:
        print("WARNING: Could not find Drop impl")

    # Replace ImageAligned::new implementation
    old_new = """impl ImageAligned {
        pub fn new(w: i32, h: i32, align: usize) -> ImageAligned {
            let size = (w * h) as usize;
            let size_bytes = size * mem::size_of::<Color>();
            let size_alignments = (size_bytes + align - 1) / align;
            let size_aligned = size_alignments * align;
            let data;
            unsafe {
                let ptr = libc::memalign(align, size_aligned);
                libc::memset(ptr, 0, size_aligned);
                data = slice::from_raw_parts_mut(
                    ptr as *mut Color,
                    size_aligned / mem::size_of::<Color>(),
                );
            }
            ImageAligned { w, h, data }
        }"""

    new_new = """impl ImageAligned {
        pub fn new(w: i32, h: i32, align: usize) -> ImageAligned {
            let size = (w * h) as usize;
            let size_bytes = size * mem::size_of::<Color>();
            let size_alignments = (size_bytes + align - 1) / align;
            let size_aligned = size_alignments * align;

            // Over-allocate by align to guarantee we can find an aligned address
            // This is necessary because libc::memalign in relibc may not work correctly
            let alloc_size = size_aligned + align;
            let data;
            let alloc_ptr;
            unsafe {
                // Use malloc instead of memalign, then manually align
                alloc_ptr = libc::malloc(alloc_size) as *mut u8;
                if alloc_ptr.is_null() {
                    panic!("ImageAligned: allocation failed");
                }

                // Align the pointer up to the next boundary
                let alloc_addr = alloc_ptr as usize;
                let aligned_addr = (alloc_addr + align - 1) & !(align - 1);
                let aligned_ptr = aligned_addr as *mut u8;

                // Zero the aligned region
                libc::memset(aligned_ptr as *mut libc::c_void, 0, size_aligned);

                data = slice::from_raw_parts_mut(
                    aligned_ptr as *mut Color,
                    size_aligned / mem::size_of::<Color>(),
                );

                eprintln!(
                    "ImageAligned: alloc_addr={:#x}, aligned_addr={:#x}, page_aligned={}",
                    alloc_addr, aligned_addr, aligned_addr % align == 0
                );
            }
            ImageAligned { w, h, data, alloc_ptr, alloc_size }
        }"""

    if old_new in content:
        content = content.replace(old_new, new_new)
        print("Replaced ImageAligned::new impl")
    else:
        print("WARNING: Could not find ImageAligned::new impl")

    with open(file_path, 'w') as f:
        f.write(content)

    print("ImageAligned patching complete")
    PATCH_EOF
              echo "ImageAligned patch applied"
            fi

            runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor orbital's dependencies (now includes graphics-ipc with local drm-rs path)
  orbitalVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "orbital-cargo-vendor";
    src = patchedSrc;
    hash = "sha256-eVao4g4+FyhhM8A+yJDLFg2+aKjKStwUZtlfBq61vVY=";
  };

  # Create merged vendor directory (project + sysroot)
  mergedVendor = vendor.mkMergedVendor {
    name = "orbital";
    projectVendor = orbitalVendor;
    inherit sysrootVendor;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/base.git";
      git = "https://gitlab.redox-os.org/redox-os/base.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/orbclient.git";
      git = "https://gitlab.redox-os.org/redox-os/orbclient.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/relibc.git";
      git = "https://gitlab.redox-os.org/redox-os/relibc.git";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "orbital";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
  ];

  buildInputs = [ relibc ];

  TARGET = redoxTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
    runHook preConfigure

    cp -r ${patchedSrc}/* .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    ${vendor.mkCargoConfig {
      inherit gitSources;
      target = redoxTarget;
      linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
      panic = "abort";
    }}
  CARGOCONF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    export ${rustFlags.cargoEnvVar}="${rustFlags.userRustFlags} -L ${stubLibs}/lib"

    cargo build \
      --bin orbital \
      --target ${redoxTarget} \
      --release \
      ${lib.concatStringsSep " \\\n      " rustFlags.buildStdArgs}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/orbital $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Orbital: Display Server and Window Manager for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/orbital";
    license = licenses.mit;
  };
}
