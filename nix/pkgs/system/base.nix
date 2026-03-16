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
  # Import rust-flags — useToolchainRlibs=true by default
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  needsBuildStd = !rustFlags.useToolchainRlibs;

  # Patch for GraphicScreen to use mmap for page-aligned allocation
  # Version: 2 - Fixed patch format
  graphicscreenPatch = ../patches/graphicscreen-mmap.patch;
  graphicscreenPatchPy = ../patches/graphicscreen-mmap.py;

  # Patches for virtio-netd RX buffer recycling and IRQ wakeup
  virtioNetRxPatch = ../patches/virtio-netd-rx-recycle.patch;
  virtioNetIrqPatch = ../patches/virtio-netd-irq-wakeup.patch;

  # Patch for randd to allow reads from scheme root handles (unified diff)
  randdPatch = ../patches/randd-scheme-root-read.patch;

  # virtio-fsd driver source (injected into base workspace)
  virtioFsdSrc = ./virtio-fsd;

  # Cargo.toml for virtio-fsd (external to avoid heredoc indentation issues in patchPhase)
  virtioFsdCargoToml = pkgs.writeText "virtio-fsd-Cargo.toml" ''
    [package]
    name = "virtio-fsd"
    version = "0.1.0"
    edition = "2021"
    description = "VirtIO filesystem driver for Redox OS (virtio-fs / FUSE over virtqueue)"

    [dependencies]
    anyhow.workspace = true
    log.workspace = true
    thiserror = "1.0.40"
    static_assertions = "1.1.0"
    futures = { version = "0.3.28", features = ["executor"] }

    redox_event.workspace = true
    redox_syscall = { workspace = true, features = ["std"] }
    redox-scheme.workspace = true

    common = { path = "../../common" }
    daemon = { path = "../../../daemon" }
    pcid = { path = "../../pcid" }
    virtio-core = { path = "../../virtio-core" }
    libredox.workspace = true
  '';

  # Prepare source with patched dependencies
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "base-src-patched-v12"; # v12: Extract graphicscreen patch to .py file
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

        # Use external Python script to avoid heredoc indentation issues
        ${pkgs.python3}/bin/python3 ${graphicscreenPatchPy} "$SCHEME_FILE"
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

      # Add Queue::repost_buffer() to virtio-core for RX buffer recycling.
      # Uses substituteInPlace (exact string match) rather than patch because
      # both Queue and PendingRequest have descriptor_len() — unified diff
      # context matching hits the wrong one.
      echo "Patching virtio-core: adding Queue::repost_buffer()..."
      substituteInPlace drivers/virtio-core/src/transport.rs \
        --replace-quiet \
          '    /// Returns the number of descriptors in the descriptor table of this queue.
    pub fn descriptor_len(&self) -> usize {
        self.descriptor.len()
    }
}' \
          '    /// Returns the number of descriptors in the descriptor table of this queue.
    pub fn descriptor_len(&self) -> usize {
        self.descriptor.len()
    }

    /// Re-post a descriptor to the available ring without allocating a new one.
    ///
    /// The descriptor table entry must already be set up with the correct buffer
    /// address, flags, and size (e.g. from initial queue population). This just
    /// adds the descriptor index back to the available ring and notifies the device.
    pub fn repost_buffer(&self, descriptor_idx: u16) {
        use core::sync::atomic::Ordering;

        let avail_idx = self.available.head_index() as usize;
        self.available
            .get_element_at(avail_idx)
            .table_index
            .store(descriptor_idx, Ordering::SeqCst);
        self.available.set_head_idx(avail_idx as u16 + 1);
        self.notification_bell.ring(self.queue_index);
    }
}'

      # Fix virtio-netd RX buffer recycling and used ring tracking
      # Bug 1: try_recv() never re-posts consumed buffers to the available ring.
      #   After ~256 packets, all RX buffers are exhausted and inbound packets are dropped.
      # Bug 2: try_recv() reads only the last used ring element (idx-1) and jumps recv_head
      #   to head_index(), skipping any intermediate packets.
      echo "Patching virtio-netd RX buffer recycling..."
      patch -p1 --fuzz=3 < ${virtioNetRxPatch}

      # Fix virtio-netd main loop to wake on IRQ events
      # Without this, the main loop only wakes on scheme requests from smolnetd.
      # When smolnetd's timer goes idle (no active sockets), nobody reads incoming
      # packets from the device, causing all inbound traffic to be ignored.
      echo "Patching virtio-netd IRQ wakeup..."
      patch -p1 --fuzz=3 < ${virtioNetIrqPatch}

      # Fix ihdad: use Immediate Command Interface for all HDA controllers
      #
      # The CORB/RIRB (DMA-based) command interface times out on QEMU's ICH6
      # intel-hda controller (vendor:device 0x8086:0x2668). The DMA ring buffers
      # are properly allocated but the hardware emulation never writes responses
      # to the RIRB, causing a 1-second timeout that panics the driver with
      # "ihdad: failed to allocate device: I/O error".
      #
      # The root cause: ihdad forces CORB/RIRB mode only for device 0x2668
      # (originally a VirtualBox workaround), while all other devices use the
      # simpler Immediate Command Interface (ICI). QEMU's intel-hda happens to
      # use the same device ID as VirtualBox, triggering the broken path.
      #
      # Fix: Always use ICI. The Immediate Command Interface is simpler (no DMA
      # ring buffers needed), works on all tested controllers, and is what the
      # driver already uses for every device except 0x2668.
      if [ -f drivers/audio/ihdad/src/hda/device.rs ]; then
        echo "Patching ihdad: always use Immediate Command Interface..."
        sed -i 's/0x8086_2668 => false/0x8086_2668 => true/' \
          drivers/audio/ihdad/src/hda/device.rs
        echo "Done patching ihdad"
      fi

      # ─── randd: allow reads from scheme root handle ───
      # Rust's std::sys::random::redox opens /scheme/rand (the scheme root)
      # and reads random bytes from it. But randd's read() only accepts
      # Handle::File, not Handle::SchemeRoot, returning EBADF.
      echo "Patching randd: allow reads from scheme root..."
      patch -p1 --fuzz=3 < ${randdPatch}

      # ─── virtio-fsd: inject driver source into workspace ───
      echo "Adding virtio-fsd driver to workspace..."
      cp -r ${virtioFsdSrc} drivers/storage/virtio-fsd
      chmod -R u+w drivers/storage/virtio-fsd

      # Fix the Cargo.toml paths (they reference ../../common etc. relative
      # to drivers/storage/virtio-fsd/, which is the same layout as virtio-blkd)
      cp ${virtioFsdCargoToml} drivers/storage/virtio-fsd/Cargo.toml
      chmod u+w drivers/storage/virtio-fsd/Cargo.toml

      # Add to workspace members
      sed -i 's|"drivers/storage/virtio-blkd",|"drivers/storage/virtio-blkd",\n    "drivers/storage/virtio-fsd",|' Cargo.toml
      echo "Done adding virtio-fsd"

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
    hash = "sha256-7EcGCW6hQCgsfykbBuT233J2axZE1/Jt68fPjKvzCE8=";
  };

  # Create merged vendor directory (cached as separate derivation)
  # With prebuilt sysroot, skip sysroot vendor merge (not needed)
  mergedVendor = vendor.mkMergedVendor {
    name = "base";
    projectVendor = baseVendor;
    sysrootVendor = if needsBuildStd then sysrootVendor else null;
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
  RUST_SRC_PATH = lib.optionalString needsBuildStd "${rustToolchain}/lib/rustlib/src/rust/library";

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
      ${lib.concatStringsSep " \\\n      " rustFlags.buildStdArgs}

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

  passthru = {
    # Expose patched source for per-crate builds via unit2nix
    src = patchedSrc;
  };

  meta = with lib; {
    description = "Redox OS Base System Components";
    homepage = "https://gitlab.redox-os.org/redox-os/base";
    license = licenses.mit;
  };
}
