# initfs - Complete initial RAM filesystem image
#
# Creates the initfs (initial RAM filesystem) that contains the minimum
# set of binaries and configuration needed to boot Redox OS. The initfs
# is loaded by the bootloader and contains:
# - Core system daemons (init, logd, ramfs, randd, zerod, etc.)
# - Storage and network drivers
# - The Ion shell
# - RedoxFS filesystem driver
# - Configuration files (init.rc, pcid configs)
#
# The initfs is created using redox-initfs-ar which prepends the bootstrap
# loader to create a self-extracting archive.

{
  pkgs,
  lib,
  initfsTools,
  bootstrap,
  base,
  ion,
  redoxfsTarget,
  # Optional: netutils for network testing commands (ping, ifconfig)
  # Note: netutils binaries are copied if available for network testing
  netutils ? null,
}:

pkgs.stdenv.mkDerivation {
  pname = "redox-initfs";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    initfsTools
  ];

  buildPhase = ''
            runHook preBuild

            # Create initfs directory structure
            # Note: /dev symlinks can't be created here because the initfs archiver
            # can't handle absolute symlinks to paths that don't exist on the host.
            # Programs needing random during initfs should use /scheme/rand directly.
            # ipcd and other daemons that use getrandom crate are started from rootfs
            # init.d scripts where /dev/urandom -> /scheme/rand symlink exists.
            mkdir -p initfs/bin initfs/lib/drivers initfs/etc/pcid initfs/usr/bin

            # Copy core binaries to bin/ (no graphics: removed vesad, fbbootlogd, fbcond, inputd)
            # Added: ipcd (IPC daemon), smolnetd (network stack)
            for bin in init logd ramfs randd zerod pcid pcid-spawner lived acpid hwd rtcd ps2d ptyd ipcd smolnetd; do
              if [ -f ${base}/bin/$bin ]; then
                cp ${base}/bin/$bin initfs/bin/
              fi
            done

            # Copy nulld (copy of zerod)
            cp ${base}/bin/zerod initfs/bin/nulld

            # Copy redoxfs
            cp ${redoxfsTarget}/bin/redoxfs initfs/bin/

            # Copy Ion shell to initfs as the primary shell
            cp ${ion}/bin/ion initfs/bin/
            cp ${ion}/bin/ion initfs/usr/bin/
            # Also provide ion as /bin/sh for compatibility
            cp ${ion}/bin/ion initfs/bin/sh
            cp ${ion}/bin/ion initfs/usr/bin/sh

            # Copy network utilities if available (for network testing in initfs)
            ${lib.optionalString (netutils != null) ''
              if [ -f ${netutils}/bin/ifconfig ]; then
                cp ${netutils}/bin/ifconfig initfs/bin/
              fi
              if [ -f ${netutils}/bin/ping ]; then
                cp ${netutils}/bin/ping initfs/bin/
              fi
            ''}

            # Copy driver binaries to lib/drivers/ (no graphics: removed virtio-gpud)
            # Added: e1000d (Intel network, QEMU default), virtio-netd (VirtIO network)
            echo "=== Copying drivers from ${base}/bin to initfs/lib/drivers ==="
            for drv in ahcid ided nvmed virtio-blkd e1000d virtio-netd; do
              if [ -f ${base}/bin/$drv ]; then
                echo "Copying $drv..."
                cp -v ${base}/bin/$drv initfs/lib/drivers/
              else
                echo "WARNING: $drv not found in ${base}/bin"
              fi
            done
            echo "=== Drivers in initfs/lib/drivers ==="
            ls -la initfs/lib/drivers/

            # Create init_drivers.rc
            cat > initfs/etc/init_drivers.rc << 'DRIVERS_RC'
    ps2d us
    echo "Starting hwd..."
    hwd
    echo "hwd completed, starting pcid-spawner..."
    pcid-spawner /scheme/initfs/etc/pcid/initfs.toml
    echo "pcid-spawner completed"
    DRIVERS_RC

            # Verify drivers are actually copied
            echo "Checking for drivers in initfs..."
            ls -la initfs/lib/drivers/ || echo "No drivers found!"

            # Create custom pcid config with network drivers added
            # NOTE: The TOML content must NOT be indented - TOML is whitespace-sensitive
            cat > initfs/etc/pcid/initfs.toml << 'EOF'
    # Drivers for InitFS (with network support)

    # Storage drivers - AHCI
    [[drivers]]
    class = 1
    subclass = 6
    command = ["/scheme/initfs/lib/drivers/ahcid"]

    # Storage drivers - IDE
    [[drivers]]
    class = 1
    subclass = 1
    command = ["/scheme/initfs/lib/drivers/ided"]

    # Storage drivers - NVME
    [[drivers]]
    class = 1
    subclass = 8
    command = ["/scheme/initfs/lib/drivers/nvmed"]

    # Storage drivers - virtio-blk (legacy device ID 0x1001)
    [[drivers]]
    vendor = 0x1AF4
    device = 0x1001
    command = ["/scheme/initfs/lib/drivers/virtio-blkd"]

    # Storage drivers - virtio-blk (modern device ID 0x1042 - Cloud Hypervisor)
    [[drivers]]
    vendor = 0x1AF4
    device = 0x1042
    command = ["/scheme/initfs/lib/drivers/virtio-blkd"]

    # Network drivers - Intel e1000 (QEMU default: 8086:100e)
    [[drivers]]
    name = "E1000 NIC"
    class = 0x02
    vendor = 0x8086
    device = 0x100e
    command = ["/scheme/initfs/lib/drivers/e1000d"]

    # Network drivers - virtio-net (legacy device ID 0x1000)
    [[drivers]]
    name = "VirtIO Net"
    class = 0x02
    vendor = 0x1AF4
    device = 0x1000
    command = ["/scheme/initfs/lib/drivers/virtio-netd"]

    # Network drivers - virtio-net (modern device ID 0x1041 - Cloud Hypervisor)
    [[drivers]]
    name = "VirtIO Net Modern"
    class = 0x02
    vendor = 0x1AF4
    device = 0x1041
    command = ["/scheme/initfs/lib/drivers/virtio-netd"]
    EOF

            # Create Ion shell configuration with simple prompt (no subprocess expansion)
            mkdir -p initfs/etc/ion
            echo '# Simple Ion shell configuration for headless Redox' > initfs/etc/ion/initrc
            echo '# Use a simple prompt without subprocess expansion' >> initfs/etc/ion/initrc
            echo 'let PROMPT = "ion> "' >> initfs/etc/ion/initrc

            # Create headless init.rc (no graphics daemons)
            # NOTE: Content must NOT be indented - init.rc format is line-by-line commands
            cat > initfs/etc/init.rc << 'EOF'
    # Headless Redox init - no graphics support
    export PATH /scheme/initfs/bin
    export RUST_BACKTRACE 1
    rtcd
    nulld
    zerod
    echo "Starting random daemon..."
    randd
    echo "."
    echo "."
    echo "."
    echo "."
    echo "."
    echo "Random daemon ready"

    # PTY daemon - needed for interactive shells
    ptyd

    # Logging
    logd
    stdio /scheme/log
    ramfs logging

    # Live disk
    lived

    # Drivers (pcid-spawner will start e1000d when it detects the network card)
    # Note: pcid is started by hwd
    echo "Loading drivers..."
    run /scheme/initfs/etc/init_drivers.rc
    unset RSDP_ADDR RSDP_SIZE

    # Note: ipcd requires /dev/urandom which only exists after rootfs mounts
    # It will be started from /usr/lib/init.d/00_base after rootfs transition

    # Mount rootfs
    # Note: init.rc is executed line-by-line by init, not by a shell, so we can't use if/then/else
    echo "Mounting RedoxFS..."
    # Use the UUID directly if available, otherwise let redoxfs find it
    redoxfs --uuid $REDOXFS_UUID file $REDOXFS_BLOCK
    unset REDOXFS_UUID REDOXFS_BLOCK REDOXFS_PASSWORD_ADDR REDOXFS_PASSWORD_SIZE

    # Exit initfs
    echo "Transitioning from initfs to root filesystem..."
    cd /
    export PATH "/bin:/usr/bin"
    echo "PATH set to: $PATH"
    echo "Running init scripts..."
    # run.d is a subcommand of init - just use run.d directly since it's part of init
    run.d /usr/lib/init.d /etc/init.d

    # Boot complete - start interactive shell
    echo ""
    echo "=========================================="
    echo "  Redox OS Boot Complete!"
    echo "=========================================="
    echo ""
    echo "Starting shell..."
    echo ""

    # Set TERM=dumb to disable fancy terminal features that may not work in QEMU
    export TERM dumb
    # Set XDG_CONFIG_HOME so Ion finds its config file with simple prompt
    export XDG_CONFIG_HOME /etc
    export HOME /home/user
    # Run Ion shell test to show it works
    echo "Testing Ion shell..."
    /bin/ion -c help
    echo ""
    echo "Ion shell is working!"
    echo ""

    # Network status
    echo "Network configured via DHCP."
    echo "Test connectivity: ping 172.16.0.1"
    echo ""
    echo "Interactive shell not available in headless mode."
    echo "Use graphical mode (nix run .#run-redox-graphical) for interactive shell."
    EOF

            # Create initfs image
            redox-initfs-ar initfs ${bootstrap}/bin/bootstrap -o initfs.img

            runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/boot
    cp initfs.img $out/boot/initfs
    runHook postInstall
  '';

  meta = with lib; {
    description = "Redox initial RAM filesystem";
    license = licenses.mit;
  };
}
