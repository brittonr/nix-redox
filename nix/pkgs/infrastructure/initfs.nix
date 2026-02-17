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
  # Enable audio support (audiod, ihdad for Intel HD Audio)
  enableAudio ? false,
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
            mkdir -p initfs/bin initfs/lib/drivers initfs/etc/pcid initfs/usr/bin initfs/usr/lib/drivers

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

            # Copy audio daemon if audio mode is enabled
            ${lib.optionalString enableAudio ''
              echo "=== Copying audio daemon ==="
              if [ -f ${base}/bin/audiod ]; then
                echo "Copying audiod..."
                cp -v ${base}/bin/audiod initfs/bin/
              else
                echo "WARNING: audiod not found in ${base}/bin"
              fi
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

              echo "=== Copying USB stack for graphics input ==="
              # xhcid: USB 3.0 host controller driver (detects QEMU's qemu-xhci)
              # usbhubd: USB hub driver (enumerates devices on the bus)
              # usbhidd: USB HID driver (handles usb-kbd and usb-tablet from QEMU)
              #
              # xhcid spawns usbhubd/usbhidd when it discovers devices. It looks for them
              # in /usr/lib/drivers/ (standard Redox path) or possibly relative paths.
              # We copy to both lib/drivers (for xhcid lookup) and bin (for PATH).
              for drv in xhcid usbhubd usbhidd; do
                if [ -f ${base}/bin/$drv ]; then
                  echo "Copying $drv to lib/drivers..."
                  cp -v ${base}/bin/$drv initfs/lib/drivers/
                else
                  echo "WARNING: $drv not found in ${base}/bin"
                fi
              done
              # Also copy to bin for PATH-based lookup
              for bin in usbhubd usbhidd; do
                if [ -f ${base}/bin/$bin ]; then
                  echo "Copying $bin to bin..."
                  cp -v ${base}/bin/$bin initfs/bin/
                else
                  echo "WARNING: $bin not found in ${base}/bin"
                fi
              done
              # Copy to /usr/lib/drivers/ (standard Redox driver path used by xhcid)
              echo "Copying USB drivers to /usr/lib/drivers/..."
              for drv in usbhubd usbhidd; do
                if [ -f ${base}/bin/$drv ]; then
                  cp -v ${base}/bin/$drv initfs/usr/lib/drivers/
                else
                  echo "WARNING: $drv not found for /usr/lib/drivers"
                fi
              done
            ''}

            # Copy audio drivers if audio mode is enabled
            ${lib.optionalString enableAudio ''
              echo "=== Copying audio drivers ==="
              # ihdad: Intel HD Audio driver (QEMU intel-hda device)
              # ac97d: AC'97 audio driver (QEMU AC97 device)
              # sb16d: Sound Blaster 16 driver (QEMU sb16 device)
              for drv in ihdad ac97d sb16d; do
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
            # Uses 'notify' prefix for daemons that use the daemon crate's readiness protocol
            cat > initfs/etc/init_drivers.rc << 'DRIVERS_RC'
    ${lib.optionalString enableGraphics "notify ps2d"}
    notify hwd
    pcid-spawner /scheme/initfs/etc/pcid/initfs.toml
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

              # USB xHCI Controller (USB 3.0) - QEMU qemu-xhci device
              # Class 0x0C = Serial Bus Controller, Subclass 0x03 = USB, Prog-IF 0x30 = xHCI
              [[drivers]]
              name = "USB xHCI"
              class = 0x0C
              subclass = 0x03
              command = ["/scheme/initfs/lib/drivers/xhcid"]
              EOF_GRAPHICS
            ''}

            # Add audio driver entries to pcid config if enabled
            ${lib.optionalString enableAudio ''
                          cat >> initfs/etc/pcid/initfs.toml << 'EOF_AUDIO'

              # Audio drivers - Intel HD Audio (QEMU intel-hda / ich9-intel-hda)
              # Class 0x04 = Multimedia, Subclass 0x03 = HD Audio
              # ICH6: vendor 0x8086, device 0x2668
              [[drivers]]
              name = "Intel HD Audio ICH6"
              class = 0x04
              subclass = 0x03
              vendor = 0x8086
              device = 0x2668
              command = ["/scheme/initfs/lib/drivers/ihdad"]

              # ICH9: vendor 0x8086, device 0x293e
              [[drivers]]
              name = "Intel HD Audio ICH9"
              class = 0x04
              subclass = 0x03
              vendor = 0x8086
              device = 0x293e
              command = ["/scheme/initfs/lib/drivers/ihdad"]

              # Audio drivers - AC'97 (QEMU AC97 device)
              # Class 0x04 = Multimedia, Subclass 0x01 = Audio
              # Intel 82801AA AC'97: vendor 0x8086, device 0x2415
              [[drivers]]
              name = "AC97 Audio"
              class = 0x04
              subclass = 0x01
              vendor = 0x8086
              device = 0x2415
              command = ["/scheme/initfs/lib/drivers/ac97d"]

              # Audio drivers - Sound Blaster 16 (QEMU sb16 device)
              # ISA device, no PCI - started manually if needed
              EOF_AUDIO
            ''}

            # Create Ion shell configuration with simple prompt (no subprocess expansion)
            mkdir -p initfs/etc/ion
            echo '# Simple Ion shell configuration for headless Redox' > initfs/etc/ion/initrc
            echo '# Use a simple prompt without subprocess expansion' >> initfs/etc/ion/initrc
            echo 'let PROMPT = "ion> "' >> initfs/etc/ion/initrc

            # Create init.rc based on graphics mode
            # Uses 'notify' prefix for daemons that use the daemon crate's readiness protocol.
            # The 'notify' command calls daemon::Daemon::spawn() which sets INIT_NOTIFY env var
            # with a pipe fd, then waits for the daemon to signal readiness before continuing.
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
    notify nulld
    notify zerod
    notify randd

    # Logging
    notify logd
    stdio /scheme/log
    notify ramfs logging

    # PTY daemon (needed for getty/interactive shells)
    notify ptyd
    EOF

            # Graphics infrastructure BEFORE drivers (matching upstream order)
            # inputd/vesad must be ready before pcid-spawner starts xhcid,
            # so usbhidd can register with the input: scheme
            ${lib.optionalString enableGraphics ''
                                cat >> initfs/etc/init.rc << 'EOF_GRAPHICS'

              # Graphics infrastructure
              notify inputd
              notify vesad
              unset FRAMEBUFFER_ADDR FRAMEBUFFER_VIRT FRAMEBUFFER_WIDTH FRAMEBUFFER_HEIGHT FRAMEBUFFER_STRIDE
              notify fbbootlogd
              # Activate framebuffer log VT, which disables kernel graphical debug
              inputd -A 1
              notify fbcond 2
              EOF_GRAPHICS
            ''}

            # Continue with lived, drivers, rootfs mount
            cat >> initfs/etc/init.rc << 'EOF'

    # Live disk (before drivers so it gets priority for disk search)
    notify lived

    # Drivers
    run /scheme/initfs/etc/init_drivers.rc
    unset RSDP_ADDR RSDP_SIZE

    # Mount rootfs
    redoxfs --uuid $REDOXFS_UUID file $REDOXFS_BLOCK
    unset REDOXFS_UUID REDOXFS_BLOCK REDOXFS_PASSWORD_ADDR REDOXFS_PASSWORD_SIZE

    # Exit initfs
    cd /
    export PATH /usr/bin
    unset LD_LIBRARY_PATH
    run.d /usr/lib/init.d /etc/init.d

    # Boot complete
    echo ""
    echo "=========================================="
    echo "  Redox OS Boot Complete!"
    echo "=========================================="
    echo ""

    # Start interactive shell on serial console
    # Use stdio debug: to redirect init's stdin/stdout/stderr back to serial
    # (it was redirected to /scheme/log earlier for daemon startup)
    # Then run ion directly - bypasses PTY layer to diagnose serial input
    stdio debug:
    export TERM xterm
    export XDG_CONFIG_HOME /etc
    export HOME /home/user
    export USER user
    export PATH /bin:/usr/bin
    echo "Starting interactive shell on serial console..."
    echo "Type 'help' for commands, 'exit' to quit"
    echo ""
    /bin/ion
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
