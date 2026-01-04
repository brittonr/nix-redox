# Disk Image - Bootable UEFI disk image for Redox OS
#
# Creates a 512MB GPT disk with:
# - EFI System Partition (200MB FAT32) containing bootloader, kernel, initfs
# - RedoxFS partition containing the root filesystem
#
# The root filesystem includes:
# - Boot components (kernel, initfs) for RedoxFS boot fallback
# - System utilities from base package
# - Coreutils from uutils
# - Ion shell (default shell)
# - Optional userspace packages (helix, binutils, extrautils, sodium, netutils)
# - Init scripts for daemon startup

{
  pkgs,
  lib,
  # Host tool for creating RedoxFS
  redoxfs,
  # Boot components (required)
  kernel,
  bootloader,
  initfs,
  # System packages (required)
  base,
  # Shell (required)
  ion,
  # Optional userspace packages
  uutils ? null,
  helix ? null,
  binutils ? null,
  extrautils ? null,
  sodium ? null,
  netutils ? null,
  # Orbital graphics packages (optional)
  orbdata ? null,
  orbital ? null,
  orbterm ? null,
  # Enable graphics support (Orbital desktop)
  enableGraphics ? false,
  # Network configuration mode:
  # - "auto": Try DHCP first, fallback to static config if no IP assigned (default)
  # - "dhcp": DHCP only, no static fallback (for QEMU user-mode networking)
  # - "static": Apply static config immediately, skip DHCP (for Cloud Hypervisor)
  # - "none": No automatic network configuration
  networkMode ? "auto",
  # Static IP configuration (used when networkMode is "static" or "auto" fallback)
  staticNetworkConfig ? {
    ip = "172.16.0.2";
    netmask = "255.255.255.0";
    gateway = "172.16.0.1";
  },
}:

pkgs.stdenv.mkDerivation {
  pname = "redox-disk-image";
  version = "unstable";

  dontUnpack = true;
  dontPatchELF = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    parted # parted for partitioning (better GPT handling)
    mtools # for FAT filesystem
    dosfstools # mkfs.vfat
    redoxfs # redoxfs-ar for creating populated RedoxFS
  ];

  # Include all packages for populating root filesystem
  buildInputs = [
    base
    ion
  ]
  ++ lib.optional (uutils != null) uutils
  ++ lib.optional (helix != null) helix
  ++ lib.optional (binutils != null) binutils
  ++ lib.optional (extrautils != null) extrautils
  ++ lib.optional (sodium != null) sodium
  ++ lib.optional (netutils != null) netutils
  ++ lib.optional (orbdata != null) orbdata
  ++ lib.optional (orbital != null) orbital
  ++ lib.optional (orbterm != null) orbterm;

  # Use a fixed timestamp for reproducible builds
  # This ensures identical inputs produce identical outputs
  SOURCE_DATE_EPOCH = "1";

  buildPhase = ''
        runHook preBuild

        # Create 512MB disk image (increased for larger ESP)
        IMAGE_SIZE=$((512 * 1024 * 1024))
        ESP_SIZE=$((200 * 1024 * 1024))
        ESP_SECTORS=$((ESP_SIZE / 512))
        REDOXFS_START=$((2048 + ESP_SECTORS))
        # Leave 34 sectors for backup GPT at end
        REDOXFS_END=$(($(($IMAGE_SIZE / 512)) - 34))
        REDOXFS_SECTORS=$((REDOXFS_END - REDOXFS_START))

        truncate -s $IMAGE_SIZE disk.img

        # Create GPT partition table using parted
        parted -s disk.img mklabel gpt
        parted -s disk.img mkpart ESP fat32 1MiB 201MiB
        parted -s disk.img set 1 boot on
        parted -s disk.img set 1 esp on
        parted -s disk.img mkpart RedoxFS 201MiB 100%

        # Calculate partition sizes
        ESP_OFFSET=$((2048 * 512))
        REDOXFS_OFFSET=$((REDOXFS_START * 512))
        REDOXFS_SIZE=$((REDOXFS_SECTORS * 512))

        # Create FAT32 EFI System Partition
        truncate -s $ESP_SIZE esp.img
        mkfs.vfat -F 32 -n "EFI" esp.img

        # Create EFI directory structure and copy bootloader, kernel, initfs
        mmd -i esp.img ::EFI
        mmd -i esp.img ::EFI/BOOT
        mcopy -i esp.img ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI ::EFI/BOOT/
        mcopy -i esp.img ${kernel}/boot/kernel ::EFI/BOOT/kernel
        mcopy -i esp.img ${initfs}/boot/initfs ::EFI/BOOT/initfs

        # Create startup.nsh for automatic boot
        echo '\EFI\BOOT\BOOTX64.EFI' > startup.nsh
        mcopy -i esp.img startup.nsh ::

        # Copy ESP into disk image (at 1MiB = sector 2048)
        dd if=esp.img of=disk.img bs=512 seek=2048 conv=notrunc

        # Create RedoxFS root directory structure
        # The bootloader looks for boot/kernel and boot/initfs inside RedoxFS
        mkdir -p redoxfs-root/boot
        cp ${kernel}/boot/kernel redoxfs-root/boot/kernel
        cp ${initfs}/boot/initfs redoxfs-root/boot/initfs

        # Create directory structure
        mkdir -p redoxfs-root/bin
        mkdir -p redoxfs-root/usr/bin
        mkdir -p redoxfs-root/usr/lib/init.d
        mkdir -p redoxfs-root/etc/init.d
        mkdir -p redoxfs-root/tmp
        mkdir -p redoxfs-root/dev
        mkdir -p redoxfs-root/sys
        mkdir -p redoxfs-root/proc
        mkdir -p redoxfs-root/home/user

        # Create /dev symlinks for compatibility with getrandom crate and other tools
        # These symlinks point to the appropriate scheme paths
        ln -s /scheme/rand redoxfs-root/dev/urandom
        ln -s /scheme/rand redoxfs-root/dev/random
        ln -s /scheme/null redoxfs-root/dev/null
        ln -s /scheme/zero redoxfs-root/dev/zero
        # Additional standard device symlinks
        ln -s libc:tty redoxfs-root/dev/tty
        ln -s libc:stdin redoxfs-root/dev/stdin
        ln -s libc:stdout redoxfs-root/dev/stdout
        ln -s libc:stderr redoxfs-root/dev/stderr

        # Copy all binaries from base to provide utilities
        echo "Copying base system utilities..."
        if [ -d "${base}/bin" ]; then
          # Copy to both /bin and /usr/bin for compatibility
          cp -r ${base}/bin/* redoxfs-root/bin/ 2>/dev/null || true
          cp -r ${base}/bin/* redoxfs-root/usr/bin/ 2>/dev/null || true
          echo "Copied base utilities"
        fi

        # Copy uutils (coreutils) - CRITICAL for basic commands!
        ${lib.optionalString (uutils != null) ''
          echo "Copying uutils coreutils..."
          if [ -d "${uutils}/bin" ]; then
            # Copy to both /bin and /usr/bin for compatibility
            cp -r ${uutils}/bin/* redoxfs-root/bin/ 2>/dev/null || true
            cp -r ${uutils}/bin/* redoxfs-root/usr/bin/ 2>/dev/null || true
            echo "Copied uutils coreutils (ls, head, cat, etc.)"

            # Verify key utilities are present
            echo "Verifying essential utilities:"
            ls -la redoxfs-root/bin/ls redoxfs-root/bin/head redoxfs-root/bin/cat 2>/dev/null || echo "Warning: Some essential utilities missing!"
          else
            echo "ERROR: uutils not found at ${uutils}/bin!"
            exit 1
          fi
        ''}

        # Copy Ion shell - the primary shell for Redox
        echo "Copying Ion shell..."
        if [ -d "${ion}/bin" ]; then
          # Ensure directories exist
          mkdir -p redoxfs-root/bin
          mkdir -p redoxfs-root/usr/bin

          cp -v ${ion}/bin/ion redoxfs-root/bin/
          cp -v ${ion}/bin/ion redoxfs-root/usr/bin/

          # Create sh/dash symlinks pointing to ion for compatibility
          ln -sf ion redoxfs-root/bin/sh
          ln -sf ion redoxfs-root/bin/dash
          ln -sf ion redoxfs-root/usr/bin/sh
          ln -sf ion redoxfs-root/usr/bin/dash

          echo "Copied Ion shell and created sh/dash symlinks successfully"
          ls -la redoxfs-root/bin/ion redoxfs-root/bin/sh || echo "Warning: /bin/ion or /bin/sh missing!"
        else
          echo "ERROR: Ion shell not found at ${ion}/bin!"
          exit 1
        fi

        # Copy helix text editor
        ${lib.optionalString (helix != null) ''
          echo "Copying Helix editor..."
          if [ -f "${helix}/bin/helix" ]; then
            cp -v ${helix}/bin/helix redoxfs-root/bin/
            echo "Copied helix successfully"
          else
            echo "WARNING: Helix not found at ${helix}/bin - continuing without it"
          fi
        ''}

        # Copy binutils (strings, hex, hexdump)
        ${lib.optionalString (binutils != null) ''
          echo "Copying binutils..."
          if [ -d "${binutils}/bin" ]; then
            cp -rv ${binutils}/bin/* redoxfs-root/bin/ 2>/dev/null || true
            echo "Copied binutils (strings, hex, hexdump)"
          else
            echo "WARNING: binutils not found at ${binutils}/bin"
          fi
        ''}

        # Copy extrautils (grep, tar, gzip, less, etc.)
        ${lib.optionalString (extrautils != null) ''
          echo "Copying extrautils..."
          if [ -d "${extrautils}/bin" ]; then
            cp -rv ${extrautils}/bin/* redoxfs-root/bin/ 2>/dev/null || true
            cp -rv ${extrautils}/bin/* redoxfs-root/usr/bin/ 2>/dev/null || true
            echo "Copied extrautils (grep, tar, gzip, less, dmesg, watch, etc.)"
          else
            echo "WARNING: extrautils not found at ${extrautils}/bin"
          fi
        ''}

        # Copy sodium editor
        ${lib.optionalString (sodium != null) ''
          echo "Copying sodium editor..."
          if [ -f "${sodium}/bin/sodium" ]; then
            cp -v ${sodium}/bin/sodium redoxfs-root/bin/
            # Create vi symlink for familiarity
            ln -sf sodium redoxfs-root/bin/vi
            echo "Copied sodium editor (also available as 'vi')"
          else
            echo "WARNING: sodium not found at ${sodium}/bin"
          fi
        ''}

        # Copy network utilities (dhcpd, dnsd, ping, ifconfig, nc)
        ${lib.optionalString (netutils != null) ''
          echo "Copying network utilities..."
          if [ -d "${netutils}/bin" ]; then
            cp -rv ${netutils}/bin/* redoxfs-root/bin/ 2>/dev/null || true
            cp -rv ${netutils}/bin/* redoxfs-root/usr/bin/ 2>/dev/null || true
            echo "Copied netutils (dhcpd, dns, ping, ifconfig, nc)"
          else
            echo "WARNING: netutils not found at ${netutils}/bin"
          fi
        ''}

        # Copy Orbital graphics packages
        ${lib.optionalString (orbdata != null) ''
          echo "Copying Orbital data files (fonts, icons, cursors)..."
          # orbdata contains: backgrounds/, cursors/, fonts/, icons/
          # These go to /ui/ directory in Redox
          mkdir -p redoxfs-root/ui
          for dir in backgrounds cursors fonts icons; do
            if [ -d "${orbdata}/$dir" ]; then
              cp -rv ${orbdata}/$dir redoxfs-root/ui/
            fi
          done
          echo "Copied orbdata to /ui/"
        ''}

        ${lib.optionalString (orbital != null) ''
          echo "Copying Orbital display server..."
          if [ -f "${orbital}/bin/orbital" ]; then
            cp -v ${orbital}/bin/orbital redoxfs-root/bin/
            echo "Copied orbital display server"
          else
            echo "WARNING: orbital not found at ${orbital}/bin"
          fi
        ''}

        ${lib.optionalString (orbterm != null) ''
          echo "Copying Orbital terminal emulator..."
          if [ -f "${orbterm}/bin/orbterm" ]; then
            cp -v ${orbterm}/bin/orbterm redoxfs-root/bin/
            echo "Copied orbterm terminal"
          fi
          # Copy UI app configs if present
          if [ -d "${orbterm}/ui/apps" ]; then
            mkdir -p redoxfs-root/ui/apps
            cp -rv ${orbterm}/ui/apps/* redoxfs-root/ui/apps/
          fi
        ''}

        # Create network configuration directory and files
        echo "Creating network configuration..."
        mkdir -p redoxfs-root/etc/net

        # DNS server configuration (use Cloudflare and Google DNS)
        echo "1.1.1.1" > redoxfs-root/etc/net/dns
        echo "8.8.8.8" >> redoxfs-root/etc/net/dns

        # Default router for QEMU user-mode networking (10.0.2.2)
        # Cloud Hypervisor uses 172.16.0.1 - configure via netcfg or ifconfig
        echo "10.0.2.2" > redoxfs-root/etc/net/ip_router

        # Cloud Hypervisor network configuration (when TAP networking is used)
        # These files are read by network configuration scripts
        # Values come from staticNetworkConfig parameter
        mkdir -p redoxfs-root/etc/net/cloud-hypervisor
        echo "${staticNetworkConfig.ip}" > redoxfs-root/etc/net/cloud-hypervisor/ip
        echo "${staticNetworkConfig.netmask}" > redoxfs-root/etc/net/cloud-hypervisor/netmask
        echo "${staticNetworkConfig.gateway}" > redoxfs-root/etc/net/cloud-hypervisor/gateway

        # Create init.d directory with startup scripts
        # These run after rootfs is mounted, so /dev/urandom symlink exists
        mkdir -p redoxfs-root/etc/init.d
        mkdir -p redoxfs-root/usr/lib/init.d

        # Base daemons (ipcd needs /dev/urandom -> /scheme/rand)
        # Note: ptyd is already started in initfs, don't start again
        cat > redoxfs-root/usr/lib/init.d/00_base << 'INIT_BASE'
    /bin/ipcd
    INIT_BASE

        # Network daemons
        cat > redoxfs-root/etc/init.d/10_net << 'INIT_NET'
    /bin/smolnetd
    INIT_NET

        # DHCP daemon (skip for static-only mode)
        ${lib.optionalString (networkMode != "static") ''
              cat > redoxfs-root/etc/init.d/15_dhcp << 'INIT_DHCP'
          echo "Starting DHCP client..."
          nowait /bin/dhcpd -v eth0
          INIT_DHCP
        ''}

        # Network auto-configuration based on networkMode
        # In auto mode, dhcpd runs first, then netcfg-auto checks if IP was assigned
        # and falls back to static config if no DHCP response

        ${lib.optionalString (networkMode == "static") ''
              # Static mode: Apply static config immediately after smolnetd
              cat > redoxfs-root/etc/init.d/15_netcfg << 'INIT_NETCFG'
          /bin/netcfg-static
          INIT_NETCFG
        ''}

        ${lib.optionalString (networkMode == "auto") ''
                  # Auto mode: Run netcfg-auto after dhcpd to check if IP was assigned
                  # Falls back to static config from /etc/net/cloud-hypervisor/ if no DHCP
                  cat > redoxfs-root/etc/init.d/16_netcfg << 'INIT_NETCFG_AUTO'
          echo "Running network auto-configuration..."
          nowait /bin/netcfg-auto
          INIT_NETCFG_AUTO
        ''}

        # Orbital display server startup (if graphics enabled)
        ${lib.optionalString (enableGraphics && orbital != null) ''
          cat > redoxfs-root/usr/lib/init.d/20_orbital << 'INIT_ORBITAL'
    # Start Orbital display server and login manager
    # vesad, inputd, and graphics drivers are already started from initfs
    echo "Starting Orbital..."
    nowait orbital orbterm
    INIT_ORBITAL
          echo "Created Orbital init script at /usr/lib/init.d/20_orbital"
        ''}

        # Network configuration helper for Cloud Hypervisor
        # Can be run manually: /bin/netcfg-ch
        cat > redoxfs-root/bin/netcfg-ch << 'NETCFG_CH'
    #!/bin/ion
    # Configure network for Cloud Hypervisor TAP networking
    #
    # Usage: netcfg-ch
    #
    # This configures eth0 with:
    #   IP: 172.16.0.2/24
    #   Gateway: 172.16.0.1
    #   DNS: 1.1.1.1
    #
    # Uses /scheme/netcfg interface (like dhcpd does)

    echo "Configuring network for Cloud Hypervisor..."

    # Check if eth0 exists in netcfg
    if not exists -f /scheme/netcfg/ifaces/eth0/mac
        echo "Error: eth0 interface not found in netcfg"
        echo "Make sure virtio-netd driver is running"
        exit 1
    end

    # Read configuration from files
    let ip = $(/bin/cat /etc/net/cloud-hypervisor/ip)
    let gateway = $(/bin/cat /etc/net/cloud-hypervisor/gateway)
    let prefix = "24"

    echo "Setting IP: $ip/$prefix"
    echo "$ip/$prefix" > /scheme/netcfg/ifaces/eth0/addr/set

    echo "Setting gateway: $gateway"
    echo "default via $gateway" > /scheme/netcfg/route/add

    echo "Setting DNS: 1.1.1.1"
    echo "1.1.1.1" > /scheme/netcfg/resolv/nameserver

    echo ""
    echo "Network configured for Cloud Hypervisor!"
    echo "  IP: $ip/$prefix"
    echo "  Gateway: $gateway"
    echo "  DNS: 1.1.1.1"
    echo ""
    echo "Test with: ping 172.16.0.1"
    NETCFG_CH
        chmod +x redoxfs-root/bin/netcfg-ch

        # Auto-configuration script: waits for DHCP, falls back to static
        ${lib.optionalString (networkMode == "auto") ''
              cat > redoxfs-root/bin/netcfg-auto << 'NETCFG_AUTO'
          #!/bin/ion
          # Auto-configure network: wait for DHCP, fallback to static if no IP
          #
          # This script runs after dhcpd starts. It waits briefly for DHCP to
          # assign an IP address. If no IP is assigned (e.g., Cloud Hypervisor
          # TAP networking without DHCP server), it applies static configuration.
          #
          # Uses /scheme/netcfg interface (like dhcpd does)

          # Wait for eth0 interface
          let i:int = 0
          while test $i -lt 30
              if exists -f /scheme/netcfg/ifaces/eth0/mac
                  break
              end
              let i += 1
          end

          if not exists -f /scheme/netcfg/ifaces/eth0/mac
              echo "netcfg-auto: eth0 not found"
              exit 0
          end

          # Wait for DHCP to potentially configure network
          # Check multiple times with delays between checks
          echo "netcfg-auto: Waiting for DHCP..."
          let has_network = 0
          let check:int = 0
          while test $check -lt 15
              # Small delay between checks (busy wait since no sleep command)
              let wait:int = 0
              while test $wait -lt 500000
                  let wait += 1
              end

              # Check interface IP (dhcpd writes to ifaces/eth0/addr)
              let ip_content = $(/bin/cat /scheme/netcfg/ifaces/eth0/addr/list 2>/dev/null)
              echo "netcfg-auto: Check $check - IP: $ip_content"
              if not test "$ip_content" = ""
                  echo "netcfg-auto: Network configured via DHCP: $ip_content"
                  let has_network = 1
                  break
              end
              let check += 1
          end

          if test $has_network -eq 0
              # No DHCP response - apply static config
              if exists -f /etc/net/cloud-hypervisor/ip
                  echo "netcfg-auto: No DHCP response, applying static config..."
                  let ip = $(/bin/cat /etc/net/cloud-hypervisor/ip)
                  let gateway = $(/bin/cat /etc/net/cloud-hypervisor/gateway)
                  let prefix = "24"

                  echo "netcfg-auto: Setting IP $ip/$prefix"
                  echo "$ip/$prefix" > /scheme/netcfg/ifaces/eth0/addr/set

                  echo "netcfg-auto: Setting default route via $gateway"
                  echo "default via $gateway" > /scheme/netcfg/route/add

                  echo "netcfg-auto: Setting DNS"
                  echo "1.1.1.1" > /scheme/netcfg/resolv/nameserver

                  echo "netcfg-auto: Network configured (static)"
                  echo "  IP: $ip/$prefix"
                  echo "  Gateway: $gateway"
              else
                  echo "netcfg-auto: No static config available"
              end
          else
              echo "netcfg-auto: DHCP configuration detected, using DHCP settings"
          end
          NETCFG_AUTO
              chmod +x redoxfs-root/bin/netcfg-auto
        ''}

        # Static configuration script: applies config immediately
        # Uses pipes with /bin/cat for writes since Ion shell redirection may not work with schemes
        ${lib.optionalString (networkMode == "static") ''
              cat > redoxfs-root/bin/netcfg-static << 'NETCFG_STATIC'
          #!/bin/ion
          # Apply static network configuration immediately
          #
          # Used when networkMode="static" for Cloud Hypervisor TAP networking
          # where no DHCP server is available.
          #
          # Uses pipes with cat since direct redirection may not work with /scheme files

          echo "netcfg-static: Configuring network..."

          # Wait for eth0 interface to appear in netcfg
          let i:int = 0
          while test $i -lt 30
              if exists -f /scheme/netcfg/ifaces/eth0/mac
                  break
              end
              let i += 1
          end

          if not exists -f /scheme/netcfg/ifaces/eth0/mac
              echo "netcfg-static: eth0 interface not found in netcfg"
              exit 1
          end

          echo "netcfg-static: Found eth0 interface"

          # Read static configuration
          let ip = $(/bin/cat /etc/net/cloud-hypervisor/ip)
          let gateway = $(/bin/cat /etc/net/cloud-hypervisor/gateway)
          let prefix = "24"
          let addr = "$ip/$prefix"
          let route = "default via $gateway"

          echo "netcfg-static: Setting IP $addr"
          echo "$addr" | /bin/cat - > /scheme/netcfg/ifaces/eth0/addr/set
          let actual_ip = $(/bin/cat /scheme/netcfg/ifaces/eth0/addr/list 2>/dev/null)
          echo "netcfg-static: Verified IP: $actual_ip"

          echo "netcfg-static: Setting default route: $route"
          echo "$route" | /bin/cat - > /scheme/netcfg/route/add
          let actual_route = $(/bin/cat /scheme/netcfg/route/list 2>/dev/null)
          echo "netcfg-static: Verified route: $actual_route"

          echo "netcfg-static: Setting DNS servers"
          echo "1.1.1.1" | /bin/cat - > /scheme/netcfg/resolv/nameserver
          let actual_dns = $(/bin/cat /scheme/netcfg/resolv/nameserver 2>/dev/null)
          echo "netcfg-static: Verified DNS: $actual_dns"

          echo "netcfg-static: Network configuration complete"
          NETCFG_STATIC
              chmod +x redoxfs-root/bin/netcfg-static
        ''}

        # Create a startup script that will run Ion shell
        cat > redoxfs-root/startup.sh << 'EOF'
    #!/bin/sh
    echo ""
    echo "=========================================="
    echo "  Welcome to Redox OS"
    echo "=========================================="
    echo ""
    echo "Available programs:"
    echo "  /bin/ion   - Ion shell (full-featured)"
    echo "  /bin/sh    - Minimal shell (fallback)"
    echo ""

    # Try Ion first, fall back to minimal shell
    if [ -x /bin/ion ]; then
        echo "Starting Ion shell..."
        exec /bin/ion
    else
        echo "Ion not found, starting minimal shell..."
        exec /bin/sh -i
    fi
    EOF
        chmod +x redoxfs-root/startup.sh

        # Create init config that points to our startup script
        mkdir -p redoxfs-root/etc
        cat > redoxfs-root/etc/init.toml << 'EOF'
    [[services]]
    name = "shell"
    command = "/startup.sh"
    stdio = "debug"
    restart = false
    EOF

        # Verify the shell binary is actually there
        echo "Checking for shell binary in filesystem root..."
        ls -la redoxfs-root/bin/sh || echo "ERROR: /bin/sh is missing!"
        file redoxfs-root/bin/sh 2>/dev/null || echo "Cannot determine file type"

        # Create a simple profile
        cat > redoxfs-root/etc/profile << 'EOF'
    export PATH=/bin:/usr/bin
    export HOME=/home/user
    export USER=user
    EOF

        # Create the RedoxFS partition image using redoxfs-ar
        # redoxfs-ar creates a RedoxFS image from a directory
        echo "Contents of redoxfs-root before creating image:"
        find redoxfs-root -type f 2>/dev/null | head -20 || true
        echo "Total files: $(find redoxfs-root -type f 2>/dev/null | wc -l)"
        truncate -s $REDOXFS_SIZE redoxfs.img
        redoxfs-ar redoxfs.img redoxfs-root

        # Copy RedoxFS partition into disk image
        dd if=redoxfs.img of=disk.img bs=512 seek=$REDOXFS_START conv=notrunc

        runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp disk.img $out/redox.img

    # Also provide the boot components separately
    mkdir -p $out/boot
    cp ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/boot/
    cp ${kernel}/boot/kernel $out/boot/
    cp ${initfs}/boot/initfs $out/boot/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Redox OS bootable disk image";
    license = licenses.mit;
  };
}
