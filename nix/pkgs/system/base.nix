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
  relibc-src,
  redox-log-src,
  orbclient-src,
  redox-scheme-src,
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

  graphicscreenPatchPy = ../patches/graphicscreen-mmap.py;

  # Patch driver-network to support diagnostic read path
  patchDriverNetworkDiag = ../patches/patch-driver-network-diag.py;

  # Keep the network scheme responsive when only the RX queue raises an IRQ.
  virtioNetIrqPatch = ../patches/virtio-netd-irq-wakeup.patch;

  # Patch for randd to allow reads from scheme root handles (unified diff)
  randdPatch = ../patches/randd-scheme-root-read.patch;

  # Patch for acpi crate: implement AML Match opcode (0x89)
  patchAcpiMatchOpcode = ../patches/patch-acpi-match-opcode.py;

  # Patch for xhcid sub-driver path lookup (initfs + rootfs)
  patchXhcidDriverPaths = ../patches/patch-xhcid-driver-paths.py;

  # Patch for usbhidd timeout on input scheme open
  patchUsbhiddTimeout = ../patches/patch-usbhidd-timeout.py;

  # Patch for usbhidd resilient interrupt transfer loop
  patchUsbhiddResilientLoop = ../patches/patch-usbhidd-resilient-loop.py;

  # Patch for inputd daemon startup order (setup_logging after SchemeDaemon::new)
  patchInputdDaemonOrder = ../patches/patch-inputd-daemon-order.py;

  # Patch for smolnetd: signal daemon readiness only after netcfg is registered
  patchSmolnetdReadyOrder = ../patches/patch-smolnetd-ready-order.py;

  # virtio-fsd driver source (injected into base workspace)
  virtioFsdSrc = ./virtio-fsd;

  # igcd driver source (Intel I225/I226 2.5GbE, injected into base workspace)
  igcdSrc = ./igcd;

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
    name = "base-src-patched";
    src = base-src;

    nativeBuildInputs = [ pkgs.gnupatch ];

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    patchPhase = ''
      runHook prePatch

      # Keep current upstream registry dependencies. Resolve only the Redox
      # workspace git dependencies to the flake inputs used by the system.
      substituteInPlace Cargo.toml \
        --replace-fail 'redox-ioctl = { git = "https://gitlab.redox-os.org/redox-os/relibc.git" }' \
                       'redox-ioctl = { path = "${relibc-src}/redox-ioctl" }' \
        --replace-fail 'redox-log = { git = "https://gitlab.redox-os.org/redox-os/redox-log.git" }' \
                       'redox-log = { path = "${redox-log-src}" }' \
        --replace-fail 'orbclient = { git = "https://gitlab.redox-os.org/redox-os/orbclient.git" }' \
                       'orbclient = { path = "${orbclient-src}" }' \
        --replace-fail 'redox-scheme = { git = "https://gitlab.redox-os.org/redox-os/redox-scheme.git", default-features = false }' \
                       'redox-scheme = { path = "${redox-scheme-src}", default-features = false }'

      # Bootstrap is excluded from the workspace but also uses redox-rt.
      substituteInPlace bootstrap/Cargo.toml \
        --replace-fail 'redox-rt = { git = "https://gitlab.redox-os.org/redox-os/relibc.git", default-features = false }' \
                       'redox-rt = { path = "${relibc-src}/redox-rt", default-features = false }'

      # smolnetd must not signal readiness until NetCfgScheme::new has
      # registered the netcfg: scheme. Otherwise init can launch netcfg-setup
      # early and the open races with scheme registration.
      if [ -f netstack/src/main.rs ]; then
        echo "Patching smolnetd ready order..."
        ${pkgs.python3}/bin/python3 ${patchSmolnetdReadyOrder} netstack/src/main.rs
        echo "Done patching smolnetd ready order"
      fi

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

        # Driver discovery runs before the root filesystem is available.
        # Keep rootfs configuration later in the search order so it overrides initfs.
        substituteInPlace drivers/usb/xhcid/src/xhci/mod.rs \
          --replace-fail 'config::config("xhcid")' 'config::config_for_dirs(&[
            std::path::Path::new("/scheme/initfs/lib/xhcid.d"),
            std::path::Path::new("/scheme/initfs/etc/xhcid.d"),
            std::path::Path::new("/usr/lib/xhcid.d"),
            std::path::Path::new("/etc/xhcid.d"),
        ])'

        # Fix sub-driver paths: try multiple locations so drivers are found
        # in both initfs (/bin/) and rootfs (/usr/lib/drivers/) environments.
        echo "Patching xhcid sub-driver path lookup for initfs+rootfs..."
        ${pkgs.python3}/bin/python3 ${patchXhcidDriverPaths} drivers/usb/xhcid/src/xhci/mod.rs
        echo "Done patching xhcid"

        # Retry input:producer opens while inputd registers its scheme.
        echo "Patching inputd ProducerHandle: adding startup retries..."
        ${pkgs.python3}/bin/python3 ${patchUsbhiddTimeout} drivers/inputd/src/lib.rs
        echo "Done patching inputd ProducerHandle"

        # Move setup_logging() inside daemon callback for inputd.
        # Without this, setup_logging() runs before SchemeDaemon::new() and can
        # interfere with INIT_NOTIFY fd or cause blocking I/O.
        echo "Patching inputd daemon startup order..."
        ${pkgs.python3}/bin/python3 ${patchInputdDaemonOrder} drivers/inputd/src/main.rs
        echo "Done patching inputd daemon order"

        # Make usbhidd's main loop resilient to transfer errors.
        # On real xHCI hardware (Intel N100), interrupt transfers can fail
        # after the first successful report. Without this patch, the error
        # propagates via ? and crashes usbhidd, killing all USB HID input.
        echo "Patching usbhidd: resilient transfer loop + usage 0x0 fix..."
        ${pkgs.python3}/bin/python3 ${patchUsbhiddResilientLoop} drivers/input/usbhidd/src/main.rs
        echo "Done patching usbhidd"
      fi

      # Fix virtio-netd main loop to wake on IRQ events
      # Without this, the main loop only wakes on scheme requests from smolnetd.
      # When smolnetd's timer goes idle (no active sockets), nobody reads incoming
      # packets from the device, causing all inbound traffic to be ignored.
      echo "Patching virtio-netd IRQ wakeup..."
      patch -p1 --fuzz=0 < ${virtioNetIrqPatch}

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
      patch -p1 --fuzz=0 < ${randdPatch}

      # ─── igcd: inject Intel I225/I226 network driver into workspace ───
      echo "Adding igcd network driver to workspace..."
      cp -r ${igcdSrc} drivers/net/igcd
      chmod -R u+w drivers/net/igcd

      # Write Cargo.toml (same deps as e1000d)
      cat > drivers/net/igcd/Cargo.toml << 'IGCD_CARGO_EOF'
      [package]
      name = "igcd"
      description = "Intel I225/I226 2.5GbE network driver"
      version = "0.1.0"
      edition = "2021"

      [dependencies]
      bitflags.workspace = true
      log.workspace = true
      libredox.workspace = true
      redox_event.workspace = true
      redox_syscall.workspace = true

      common = { path = "../../common" }
      daemon = { path = "../../../daemon" }
      driver-network = { path = "../driver-network" }
      pcid = { path = "../../pcid" }

      [lints]
      workspace = true
IGCD_CARGO_EOF

      # Add igcd to workspace members
      sed -i 's|"drivers/net/e1000d",|"drivers/net/e1000d",\n    "drivers/net/igcd",|' Cargo.toml
      echo "Done adding igcd"

      # Patch driver-network: add diagnostic read path ("diag" scheme file)
      echo "Patching driver-network: adding diag read path..."
      ${pkgs.python3}/bin/python3 ${patchDriverNetworkDiag} .
      echo "Done patching driver-network"

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

      # Forward ptrace handle opens (trace, mem) from procmgr to kernel
      ${pkgs.python3}/bin/python3 ${./patches/bootstrap/patch-procmgr-ptrace-forward.py} .
      echo "procmgr ptrace forwarding patch applied"

      # pcid_interface::PciFunctionHandle::map_bar now requires a MemoryType.
      substituteInPlace drivers/net/igcd/src/main.rs \
        --replace-fail 'use pcid_interface::PciFunctionHandle;' $'use common::MemoryType;\nuse pcid_interface::PciFunctionHandle;' \
        --replace-fail 'pcid_handle.map_bar(0)' 'pcid_handle.map_bar(0, MemoryType::Uncacheable)'

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
    hash = "sha256-6GZP4cw0vwGGSAVApZ6CSt2pZfLAQTktDf10dt7K+kk=";
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
      url = "git+https://gitlab.redox-os.org/redox-os/acpi.git?branch=redox-6.x";
      git = "https://gitlab.redox-os.org/redox-os/acpi.git";
      branch = "redox-6.x";
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
      url = "git+https://github.com/jackpot51/hidreport";
      git = "https://github.com/jackpot51/hidreport";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/redox-rings.git";
      git = "https://gitlab.redox-os.org/redox-os/redox-rings.git";
    }
    {
      url = "git+https://github.com/repnop/fdt.git?rev=059bb23";
      git = "https://github.com/repnop/fdt.git";
      rev = "059bb23";
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

      # Patch vendored acpi crate: implement AML Match opcode (0x89)
      # This must happen after vendor-combined is created and writable.
      echo "Patching vendored acpi crate: Match opcode implementation..."
      ACPI_DIR=$(find vendor-combined -maxdepth 1 -name "acpi*" -type d | head -1)
      if [ -n "$ACPI_DIR" ] && [ -f "$ACPI_DIR/src/aml/mod.rs" ]; then
        ${pkgs.python3}/bin/python3 ${patchAcpiMatchOpcode} vendor-combined
        # Clear cargo checksum so cargo doesn't reject the patched files
        echo '{"files":{}}' > "$ACPI_DIR/.cargo-checksum.json"
        echo "acpi Match opcode patch applied"
      else
        echo "WARNING: acpi crate not found in vendor-combined, skipping Match opcode patch"
      fi

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

    # xhcid discovers USB class drivers from runtime configuration.
    mkdir -p $out/usr/lib/xhcid.d
    cp drivers/usb/xhcid/drivers.toml $out/usr/lib/xhcid.d/

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
