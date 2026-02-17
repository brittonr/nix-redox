# Redox Base - Essential system components (cross-compiled)
#
# The base package contains essential system components:
# - init: System initialization
# - Various drivers: ps2d, pcid, nvmed, etc.
# - Core daemons: ipcd, logd, ptyd, etc.
# - Basic utilities
#
# Uses FOD (fetchCargoVendor) for reliable offline builds

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  base-src,
  liblibc-src,
  orbclient-src,
  rustix-redox-src,
  drm-rs-src,
  relibc-src,
  redox-log-src,
  fdt-src,
  # Accept but ignore extra args from commonArgs
  craneLib ? null,
  ...
}:

let
  # Import rust-flags for centralized RUSTFLAGS
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  # Patch for GraphicScreen to use mmap for page-aligned allocation
  # Version: 2 - Fixed patch format
  graphicscreenPatch = ../patches/graphicscreen-mmap.patch;

  # Patches for virtio-netd RX buffer recycling and IRQ wakeup
  virtioNetPatch = ../patches/virtio-netd-rx-recycle.py;
  virtioCorePatch = ../patches/virtio-core-repost-buffer.py;
  virtioNetIrqPatch = ../patches/virtio-netd-irq-wakeup.py;

  # Prepare source with patched dependencies
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "base-src-patched-v9"; # v9: Fix virtio-netd RX buffer recycling
    src = base-src;

    nativeBuildInputs = [ pkgs.gnupatch ];

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    patchPhase = ''
            runHook prePatch

            # Replace git dependencies with path dependencies in Cargo.toml
            # The [patch.crates-io] section needs to point to local paths
            substituteInPlace Cargo.toml \
              --replace-quiet 'libc = { git = "https://gitlab.redox-os.org/redox-os/liblibc.git", branch = "redox-0.2" }' \
                             'libc = { path = "${liblibc-src}" }' \
              --replace-quiet 'orbclient = { git = "https://gitlab.redox-os.org/redox-os/orbclient.git", version = "0.3.44" }' \
                             'orbclient = { path = "${orbclient-src}" }' \
              --replace-quiet 'rustix = { git = "https://github.com/jackpot51/rustix.git", branch = "redox-ioctl" }' \
                             'rustix = { path = "${rustix-redox-src}" }' \
              --replace-quiet 'drm = { git = "https://github.com/Smithay/drm-rs.git" }' \
                             'drm = { path = "${drm-rs-src}" }' \
              --replace-quiet 'drm-sys = { git = "https://github.com/Smithay/drm-rs.git" }' \
                             'drm-sys = { path = "${drm-rs-src}/drm-ffi/drm-sys" }'

            # Replace redox-log git dependency with local path
            substituteInPlace Cargo.toml \
              --replace-quiet 'redox-log = { git = "https://gitlab.redox-os.org/redox-os/redox-log.git" }' \
                             'redox-log = { path = "${redox-log-src}" }'

            # Add patch for redox-rt from relibc (used by individual crates)
            # Append to the [patch.crates-io] section
            echo "" >> Cargo.toml
            echo '# Added by Nix build' >> Cargo.toml
            echo 'redox-rt = { path = "${relibc-src}/redox-rt" }' >> Cargo.toml

            # Patch all git dependencies across ALL Cargo.toml files in the workspace
            find . -name Cargo.toml -exec sed -i \
              -e 's|redox-rt = { git = "https://gitlab.redox-os.org/redox-os/relibc.git"[^}]*}|redox-rt = { path = "${relibc-src}/redox-rt", default-features = false }|g' \
              -e 's|redox-log = { git = "https://gitlab.redox-os.org/redox-os/redox-log.git"[^}]*}|redox-log = { path = "${redox-log-src}" }|g' \
              -e 's|fdt = { git = "https://github.com/repnop/fdt.git"[^}]*}|fdt = { path = "${fdt-src}" }|g' \
              {} +

            # Apply GraphicScreen page-aligned allocation patch
            # This fixes the "Invalid argument" error when Orbital tries to mmap the display
            # The kernel requires page-aligned addresses from scheme mmap_prep responses
            # We use manual over-allocation with alignment instead of mmap for simplicity
            if [ -f drivers/graphics/vesad/src/scheme.rs ]; then
              echo "Applying GraphicScreen page-aligned allocation patch..."
              SCHEME_FILE="drivers/graphics/vesad/src/scheme.rs"

              # Use Python for all the replacements
              ${pkgs.python3}/bin/python3 - "$SCHEME_FILE" << 'EOF'
      import sys
      import re

      file_path = sys.argv[1]
      with open(file_path, 'r') as f:
          content = f.read()

      # Replace ptr import to remove NonNull
      content = content.replace('use std::ptr::{self, NonNull};', 'use std::ptr;')

      # Replace GraphicScreen struct - need to handle the new fields
      old_struct = """pub struct GraphicScreen {
          width: usize,
          height: usize,
          ptr: NonNull<[u32]>,
      }"""

      # Store both the aligned pointer and the original allocation pointer for proper deallocation
      new_struct = """pub struct GraphicScreen {
          width: usize,
          height: usize,
          // Aligned pointer to framebuffer data (page-aligned for kernel mmap)
          ptr: *mut u32,
          // Original allocation pointer (for deallocation)
          alloc_ptr: *mut u8,
          // Number of pixels
          len: usize,
          // Layout for deallocation
          alloc_layout: Layout,
      }"""

      if old_struct in content:
          content = content.replace(old_struct, new_struct)
          print("Replaced GraphicScreen struct")
      else:
          print("WARNING: Could not find GraphicScreen struct")

      # Replace impl GraphicScreen block with new() that does manual alignment
      old_impl = """impl GraphicScreen {
          fn new(width: usize, height: usize) -> GraphicScreen {
              let len = width * height;
              let layout = Self::layout(len);
              let ptr = unsafe { alloc::alloc_zeroed(layout) };
              let ptr = ptr::slice_from_raw_parts_mut(ptr.cast(), len);
              let ptr = NonNull::new(ptr).unwrap_or_else(|| alloc::handle_alloc_error(layout));

              GraphicScreen { width, height, ptr }
          }

          #[inline]
          fn layout(len: usize) -> Layout {
              // optimizes to an integer mul
              Layout::array::<u32>(len)
                  .unwrap()
                  .align_to(PAGE_SIZE)
                  .unwrap()
          }
      }"""

      # New implementation uses over-allocation to guarantee page alignment
      new_impl = """impl GraphicScreen {
          fn new(width: usize, height: usize) -> GraphicScreen {
              let len = width * height;
              let byte_size = len * std::mem::size_of::<u32>();

              // Over-allocate by PAGE_SIZE to guarantee we can find a page-aligned address
              // within the allocation. This is necessary because the kernel fmap validation
              // requires page-aligned base addresses.
              let alloc_size = byte_size + PAGE_SIZE;
              let alloc_layout = Layout::from_size_align(alloc_size, std::mem::align_of::<u32>())
                  .expect("Failed to create layout");

              let alloc_ptr = unsafe { alloc::alloc_zeroed(alloc_layout) };
              if alloc_ptr.is_null() {
                  alloc::handle_alloc_error(alloc_layout);
              }

              // Align the pointer up to the next page boundary
              let alloc_addr = alloc_ptr as usize;
              let aligned_addr = (alloc_addr + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
              let ptr = aligned_addr as *mut u32;

              eprintln!(
                  "GraphicScreen: alloc_addr={:#x}, aligned_addr={:#x}, page_aligned={}",
                  alloc_addr, aligned_addr, aligned_addr % PAGE_SIZE == 0
              );

              GraphicScreen { width, height, ptr, alloc_ptr, len, alloc_layout }
          }
      }"""

      if old_impl in content:
          content = content.replace(old_impl, new_impl)
          print("Replaced impl GraphicScreen block")
      else:
          print("WARNING: Could not find impl GraphicScreen block")

      # Replace Drop impl
      old_drop = """impl Drop for GraphicScreen {
          fn drop(&mut self) {
              let layout = Self::layout(self.ptr.len());
              unsafe { alloc::dealloc(self.ptr.as_ptr().cast(), layout) };
          }
      }"""

      new_drop = """impl Drop for GraphicScreen {
          fn drop(&mut self) {
              // Deallocate using the original allocation pointer, not the aligned one
              unsafe { alloc::dealloc(self.alloc_ptr, self.alloc_layout) };
          }
      }"""

      if old_drop in content:
          content = content.replace(old_drop, new_drop)
          print("Replaced Drop impl")
      else:
          print("WARNING: Could not find Drop impl")

      # Replace all remaining .as_ptr() usages on ptr fields (may appear in different contexts)
      # The .as_ptr() method doesn't exist on raw pointers
      # Use regex to handle potential whitespace variations

      # self.ptr.as_ptr() as *mut u32 -> self.ptr
      content = re.sub(r'self\.ptr\.as_ptr\(\)\s*as\s*\*mut\s*u32', 'self.ptr', content)

      # framebuffer.ptr.as_ptr().cast::<u8>() -> framebuffer.ptr as *mut u8
      # This is in map_dumb_framebuffer where 'framebuffer' is actually a GraphicScreen
      content = re.sub(r'framebuffer\.ptr\.as_ptr\(\)\.cast::<u8>\(\)', 'framebuffer.ptr as *mut u8', content)

      # Any other .ptr.as_ptr() patterns
      content = re.sub(r'\.ptr\.as_ptr\(\)', '.ptr', content)

      # Also replace any self.ptr.len() calls since ptr is now raw
      content = re.sub(r'self\.ptr\.len\(\)', 'self.len', content)

      print("Replaced .as_ptr() and .len() usages on ptr fields")

      with open(file_path, 'w') as f:
          f.write(content)

      print("Python patching complete")
      EOF
              echo "GraphicScreen page-aligned allocation patch applied"
            fi

            # Fix xhcid sub-driver spawning during initfs boot
            # Problem: .stdin(Stdio::null()) tries to open /dev/null which goes through
            # the file: scheme. During initfs boot, file: scheme doesn't exist yet,
            # causing ENODEV errors when spawning usbhubd/usbhidd.
            # Fix: Use Stdio::inherit() instead so stdin is inherited from parent.
            if [ -f drivers/usb/xhcid/src/xhci/mod.rs ]; then
              echo "Patching xhcid Stdio::null() -> Stdio::inherit() for initfs boot..."
              sed -i 's/\.stdin(process::Stdio::null())/.stdin(process::Stdio::inherit())/' \
                drivers/usb/xhcid/src/xhci/mod.rs
              echo "Done patching xhcid"
            fi

            # Add Queue::repost_buffer() to virtio-core for RX buffer recycling
            if [ -f drivers/virtio-core/src/transport.rs ]; then
              echo "Patching virtio-core: adding Queue::repost_buffer()..."
              ${pkgs.python3}/bin/python3 ${virtioCorePatch} drivers/virtio-core/src/transport.rs
              echo "Done patching virtio-core"
            fi

            # Fix virtio-netd RX buffer recycling and used ring tracking
            # Bug 1: try_recv() never re-posts consumed buffers to the available ring.
            #   After ~256 packets, all RX buffers are exhausted and inbound packets are dropped.
            # Bug 2: try_recv() reads only the last used ring element (idx-1) and jumps recv_head
            #   to head_index(), skipping any intermediate packets.
            # Fix: Process one entry at recv_head per call, re-post the buffer after reading.
            if [ -f drivers/net/virtio-netd/src/scheme.rs ]; then
              echo "Patching virtio-netd RX buffer recycling..."
              ${pkgs.python3}/bin/python3 ${virtioNetPatch} drivers/net/virtio-netd/src/scheme.rs
              echo "Done patching virtio-netd"
            fi

            # Fix virtio-netd main loop to wake on IRQ events
            # Without this, the main loop only wakes on scheme requests from smolnetd.
            # When smolnetd's timer goes idle (no active sockets), nobody reads incoming
            # packets from the device, causing all inbound traffic to be ignored.
            if [ -f drivers/net/virtio-netd/src/main.rs ]; then
              echo "Patching virtio-netd IRQ wakeup..."
              ${pkgs.python3}/bin/python3 ${virtioNetIrqPatch} drivers/net/virtio-netd/src/main.rs
              echo "Done patching virtio-netd IRQ wakeup"
            fi

            runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor dependencies using FOD (Fixed-Output-Derivation)
  baseVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "base-cargo-vendor";
    src = patchedSrc;
    hash = "sha256-k+52eNbx1T6E+gMI9wx2R+1zcwjnjGrvMA8VglTXxTo=";
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "base";
    projectVendor = baseVendor;
    inherit sysrootVendor;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "git+https://github.com/jackpot51/acpi.git";
      git = "https://github.com/jackpot51/acpi.git";
    }
    {
      url = "git+https://github.com/repnop/fdt.git";
      git = "https://github.com/repnop/fdt.git";
    }
    {
      url = "git+https://github.com/Smithay/drm-rs.git";
      git = "https://github.com/Smithay/drm-rs.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/liblibc.git?branch=redox-0.2";
      git = "https://gitlab.redox-os.org/redox-os/liblibc.git";
      branch = "redox-0.2";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/relibc.git";
      git = "https://gitlab.redox-os.org/redox-os/relibc.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/orbclient.git";
      git = "https://gitlab.redox-os.org/redox-os/orbclient.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/rehid.git";
      git = "https://gitlab.redox-os.org/redox-os/rehid.git";
    }
    {
      url = "git+https://github.com/jackpot51/range-alloc.git";
      git = "https://github.com/jackpot51/range-alloc.git";
    }
    {
      url = "git+https://github.com/jackpot51/rustix.git?branch=redox-ioctl";
      git = "https://github.com/jackpot51/rustix.git";
      branch = "redox-ioctl";
    }
    {
      url = "git+https://github.com/jackpot51/hidreport";
      git = "https://github.com/jackpot51/hidreport";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "redox-base";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.nasm
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
    pkgs.jq
    pkgs.python3
  ];

  buildInputs = [ relibc ];

  TARGET = redoxTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
    runHook preConfigure

    # Copy source with write permissions
    cp -r ${patchedSrc}/* .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    # Create cargo config
    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    ${vendor.mkCargoConfig {
      inherit gitSources;
      target = redoxTarget;
      linker = "ld.lld";
      panic = "abort";
    }}
    CARGOCONF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    # Set RUSTFLAGS for cross-linking with relibc.
    # base uses ld.lld directly (via .cargo/config.toml), not clang as linker
    # driver, so systemRustFlags omits -C linker=clang and --target, and uses
    # --allow-multiple-definition without the -Wl, prefix.
    export ${rustFlags.cargoEnvVar}="${rustFlags.systemRustFlags} -L ${stubLibs}/lib"

    # Build all workspace members for Redox target
    cargo build \
      --workspace \
      --exclude bootstrap \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    mkdir -p $out/lib

    # Copy all built binaries
    find target/${redoxTarget}/release -maxdepth 1 -type f -executable \
      ! -name "*.d" ! -name "*.rlib" \
      -exec cp {} $out/bin/ \;

    # Copy libraries if any
    find target/${redoxTarget}/release -maxdepth 1 -name "*.so" \
      -exec cp {} $out/lib/ \; 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "Redox OS Base System Components";
    homepage = "https://gitlab.redox-os.org/redox-os/base";
    license = licenses.mit;
  };
}
