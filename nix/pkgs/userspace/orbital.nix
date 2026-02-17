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
  # Use the orbital-compatible base-src (commit 620b4bd) which has graphics-ipc
  # using drm-sys 0.8.0 instead of drm 0.14, and doesn't require syscall 0.6
  base-orbital-compat-src,
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
  # Create patched source with all path dependencies resolved
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "orbital-src-patched-v9"; # v9: Fix table-format dep version bumps
    src = orbital-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    nativeBuildInputs = [ pkgs.python3 ];

    patchPhase = ''
            runHook prePatch

            # Create local copies of base subdirectories needed
            # Use orbital-compatible base commit (620b4bd) which has drm-sys 0.8.0
            mkdir -p base/drivers/graphics base/drivers/common
            cp -r ${base-orbital-compat-src}/drivers/inputd base/drivers/
            cp -r ${base-orbital-compat-src}/drivers/graphics/graphics-ipc base/drivers/graphics/
            cp -r ${base-orbital-compat-src}/drivers/common base/drivers/
            # inputd depends on daemon
            cp -r ${base-orbital-compat-src}/daemon base/

            # Make base writable for any needed patches
            chmod -R u+w base/

            # Broadly update version requirements in base subdirectories to match vendored versions.
            # The base-orbital-compat-src is pinned to an older commit with older dep versions,
            # while the orbital Cargo.lock has newer versions vendored.
            # Handle both simple ("X.Y") and table ({ version = "X.Y", ... }) formats.
            find base/ -name Cargo.toml -exec sed -i \
              -e 's|redox-scheme = "0\.[0-8][^"]*"|redox-scheme = "0.9"|g' \
              -e 's|redox_syscall = "0\.[0-5][^"]*"|redox_syscall = "0.7"|g' \
              -e '/redox_syscall/s|version = "0\.[0-5][^"]*"|version = "0.7"|g' \
              -e 's|libredox = "0\.1\.[0-9]*"|libredox = "0.1"|g' \
              -e '/libredox/s|version = "0\.1\.[0-9]*"|version = "0.1"|g' \
              {} +

            # The orbital-compatible base commit (620b4bd) has graphics-ipc using:
            # - drm-sys = "0.8.0" (from crates.io, will be vendored)
            # - No redox-ioctl dependency (that was added later)
            # - common = { path = "../../common" } (already correct)
            # So no patching needed for graphics-ipc at this commit

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

            # Strip orbclient git source from Cargo.lock to prevent fetchCargoVendor
            # from downloading both crates.io and git versions (same version number collision)
            # Remove any source lines referencing orbclient git
            sed -i '/^source = "git+https:\/\/gitlab.redox-os.org\/redox-os\/orbclient.git/d' Cargo.lock
            # Remove any source lines referencing relibc git in Cargo.lock
            sed -i '/^source = "git+https:\/\/gitlab.redox-os.org\/redox-os\/relibc.git/d' Cargo.lock

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
    hash = "sha256-ME5/M62yhh6D6pfw+PfKsnSzD0fQxntxGfM2meE3i3Y=";
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

    export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L ${stubLibs}/lib -C panic=abort -C linker=${pkgs.llvmPackages.clang-unwrapped}/bin/clang -C link-arg=-nostdlib -C link-arg=-static -C link-arg=--target=${redoxTarget} -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=-Wl,--allow-multiple-definition"

    cargo build \
      --bin orbital \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

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
