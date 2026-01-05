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
  # Optional: userutils for getty/login (terminal and authentication)
  # Note: getty is needed for proper terminal initialization with PTY support
  userutils ? null,
  # Enable graphics support (vesad, inputd, fbbootlogd, etc.)
  enableGraphics ? false,
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

            # Copy core binaries to bin/
            # Added: ipcd (IPC daemon), smolnetd (network stack)
            for bin in init logd ramfs randd zerod pcid pcid-spawner lived acpid hwd rtcd ps2d ptyd ipcd smolnetd; do
              if [ -f ${base}/bin/$bin ]; then
                cp ${base}/bin/$bin initfs/bin/
              fi
            done

            # Copy graphics daemons if graphics mode is enabled
            ${lib.optionalString enableGraphics ''
              echo "=== Copying graphics daemons ==="
              for bin in vesad inputd fbbootlogd fbcond; do
                if [ -f ${base}/bin/$bin ]; then
                  echo "Copying $bin..."
                  cp -v ${base}/bin/$bin initfs/bin/
                else
                  echo "WARNING: $bin not found in ${base}/bin"
                fi
              done
            ''}

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

            # Copy userutils binaries if available (getty for terminal, login for auth)
            # getty is essential for proper terminal initialization with PTY support
            ${lib.optionalString (userutils != null) ''
              echo "=== Copying userutils (getty, login) ==="
              for bin in getty login; do
                if [ -f ${userutils}/bin/$bin ]; then
                  echo "Copying $bin..."
                  cp -v ${userutils}/bin/$bin initfs/bin/
                else
                  echo "WARNING: $bin not found in ${userutils}/bin"
                fi
              done
            ''}

            # Copy driver binaries to lib/drivers/
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

            # Copy graphics drivers if graphics mode is enabled
            ${lib.optionalString enableGraphics ''
              echo "=== Copying graphics drivers ==="
              for drv in virtio-gpud bgad; do
                if [ -f ${base}/bin/$drv ]; then
                  echo "Copying $drv..."
                  cp -v ${base}/bin/$drv initfs/lib/drivers/
                else
                  echo "WARNING: $drv not found in ${base}/bin"
                fi
              done
            ''}

            echo "=== Drivers in initfs/lib/drivers ==="
            ls -la initfs/lib/drivers/

            # Create init_drivers.rc
            # NOTE: ps2d is moved to graphics startup section because it needs inputd to be running
            cat > initfs/etc/init_drivers.rc << 'DRIVERS_RC'
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

            # Add graphics driver entries to pcid config if enabled
            ${lib.optionalString enableGraphics ''
                          cat >> initfs/etc/pcid/initfs.toml << 'EOF_GRAPHICS'

              # Graphics drivers - VirtIO GPU (QEMU with virtio-vga)
              [[drivers]]
              name = "VirtIO GPU"
              class = 0x03
              vendor = 0x1AF4
              device = 0x1050
              command = ["/scheme/initfs/lib/drivers/virtio-gpud"]

              # Graphics drivers - Bochs Graphics Adapter (QEMU with -vga std)
              [[drivers]]
              name = "Bochs VGA"
              class = 0x03
              vendor = 0x1234
              device = 0x1111
              command = ["/scheme/initfs/lib/drivers/bgad"]
              EOF_GRAPHICS
            ''}

            # Create Ion shell configuration with simple prompt (no subprocess expansion)
            mkdir -p initfs/etc/ion
            echo '# Simple Ion shell configuration for headless Redox' > initfs/etc/ion/initrc
            echo '# Use a simple prompt without subprocess expansion' >> initfs/etc/ion/initrc
            echo 'let PROMPT = "ion> "' >> initfs/etc/ion/initrc

            # Create init.rc based on graphics mode
            # NOTE: Content must NOT be indented - init.rc format is line-by-line commands
            ${
              if enableGraphics then
                ''
                            cat > initfs/etc/init.rc << 'EOF'
                  # Redox init with graphics support
                ''
              else
                ''
                            cat > initfs/etc/init.rc << 'EOF'
                  # Headless Redox init - no graphics support
                ''
            }
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
    EOF

            # Add graphics daemons startup AFTER drivers if enabled
            # CORRECT ORDER (based on scheme dependencies):
            # 1. inputd (no -A) - creates input: scheme, but don't activate VT yet
            # 2. vesad - creates display.vesa scheme, registers DisplayHandle with inputd
            # 3. inputd -A 1 - now activate VT 1 (vesad is ready to receive it)
            # 4. ps2d - acts as input producer, needs inputd running
            # 5. fbbootlogd - uses display scheme created by vesad
            #
            # Note: The -A flag tells inputd to activate a VT, which requires a display
            # handle to be available. So we start inputd first WITHOUT -A, then vesad
            # creates the display scheme, then we activate the VT.
            ${lib.optionalString enableGraphics ''
                      cat >> initfs/etc/init.rc << 'EOF_GRAPHICS'

              # Graphics support - start display and input daemons AFTER drivers loaded
              # inputd creates input: scheme, vesad registers display handle with it
              echo "Starting input daemon (background, no VT activation)..."
              nowait inputd
              echo "Starting display daemon..."
              vesad
              echo "Starting PS/2 input driver..."
              ps2d us
              echo "Starting framebuffer boot logger..."
              nowait fbbootlogd
              EOF_GRAPHICS
            ''}

            # Continue with rest of init.rc
            cat >> initfs/etc/init.rc << 'EOF'

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

    # Boot complete
    echo ""
    echo "=========================================="
    echo "  Redox OS Boot Complete!"
    echo "=========================================="
    echo ""

    # Set environment for shell
    export TERM xterm
    export XDG_CONFIG_HOME /etc
    export HOME /home/user
    export USER user
    export PATH /bin:/usr/bin

    # Start interactive shell using PTY for proper terminal support
    # The ptyd daemon creates /scheme/pty which provides proper termios support
    # that liner/termion needs for line editing (raw mode, etc.)
    echo "Starting interactive shell..."
    echo "Type 'help' for commands, 'exit' to quit"
    echo ""
    # Use getty to properly initialize terminal and spawn login
    # -J: Don't clear the screen (useful for serial console)
    # For headless serial console, use debug: scheme
    getty -J debug:
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
