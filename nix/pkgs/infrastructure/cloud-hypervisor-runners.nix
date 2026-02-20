# Cloud Hypervisor runner scripts for RedoxOS
#
# Provides scripts for running Redox in Cloud Hypervisor:
# - headless: Serial console mode (no networking)
# - withNetwork: TAP networking mode with full connectivity + DHCP
# - withDev: Development mode with API socket for runtime control
# - setupNetwork: Helper script for host TAP/NAT configuration
# - pauseVm/resumeVm/snapshotVm/restoreVm: ch-remote wrapper scripts
#
# Cloud Hypervisor is a Rust-based VMM using virtio devices:
# - virtio-blk for storage (with direct I/O for performance)
# - virtio-net for networking (multi-queue for throughput)
# - CLOUDHV.fd firmware
#
# RedoxOS boots fully in Cloud Hypervisor with modern virtio support.
#
# Performance Features (v50+):
# - direct=on: Bypasses host page cache for better I/O performance
# - num_queues=4: Multi-queue networking for parallel packet processing
# - topology: CPU topology for better guest scheduler decisions
# - hugepages: Optional huge page support for memory performance
#
# Network Configuration:
# - Host TAP interface: 172.16.0.1/24
# - Guest IP: 172.16.0.2/24 (via DHCP from dnsmasq)
# - Guest gateway: 172.16.0.1
# - NAT via iptables for internet access

{
  pkgs,
  lib,
  diskImage,
  # Optional: Network-optimized disk image with static IP config
  # If provided, used for withNetwork runner instead of diskImage
  diskImageNet ? null,
  # VM configuration from the /virtualisation module
  vmConfig ? { },
}:

let
  cloudHypervisor = pkgs.cloud-hypervisor;
  cloudhvFirmware = pkgs.OVMF-cloud-hypervisor.fd;

  # Network configuration
  tapInterface = "tap0";
  hostIp = "172.16.0.1";
  guestIp = "172.16.0.2";
  netmask = "24";
  subnet = "172.16.0.0/24";
  guestMac = "52:54:00:12:34:56";

  # Performance configuration — driven by /virtualisation module options
  # CPU topology: threads_per_core:cores_per_die:dies_per_package:packages
  # 1:2:1:2 = 1 thread per core, 2 cores per die, 1 die per package, 2 packages = 4 vCPUs
  # This presents to guest as 2 sockets with 2 cores each (common server topology)
  cpuTopology = "1:2:1:2";
  defaultCpus = toString (vmConfig.cpus or 4);
  defaultMemory = "${toString (vmConfig.memorySize or 2048)}M";

  # Network queues: 2 = 1 RX + 1 TX (compatible with standard TAP interfaces)
  # Multi-queue (4+) requires TAP created with IFF_MULTI_QUEUE flag
  netQueues = "2";
  netQueueSize = "256";

  # Default API socket path for development mode
  defaultApiSocket = "/tmp/cloud-hypervisor-redox.sock";

  # Use network-optimized disk image if provided, otherwise fall back to default
  networkDiskImage = if diskImageNet != null then diskImageNet else diskImage;
in
{
  # Helper script to set up TAP networking on the host
  setupNetwork = pkgs.writeShellScriptBin "setup-cloud-hypervisor-network" ''
    #!/usr/bin/env bash
    set -e

    TAP_NAME="''${TAP_NAME:-${tapInterface}}"
    HOST_IP="''${HOST_IP:-${hostIp}}"
    SUBNET="''${SUBNET:-${subnet}}"

    echo "Cloud Hypervisor Network Setup"
    echo "=============================="
    echo ""
    echo "This script will configure:"
    echo "  - TAP interface: $TAP_NAME"
    echo "  - Host IP: $HOST_IP/${netmask}"
    echo "  - Subnet: $SUBNET"
    echo "  - NAT/masquerading for internet access"
    echo ""

    # Check if running as root or with sudo
    if [ "$(id -u)" -ne 0 ]; then
      echo "This script requires root privileges."
      echo "Please run with: sudo $0"
      exit 1
    fi

    # Detect the default internet interface
    DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -1)
    if [ -z "$DEFAULT_IFACE" ]; then
      echo "WARNING: Could not detect default internet interface"
      echo "NAT will not be configured. Set DEFAULT_IFACE manually if needed."
    else
      echo "Detected internet interface: $DEFAULT_IFACE"
    fi

    echo ""
    echo "Setting up TAP interface..."

    # Create TAP interface if it doesn't exist
    if ! ip link show "$TAP_NAME" &>/dev/null; then
      echo "  Creating $TAP_NAME..."
      ip tuntap add dev "$TAP_NAME" mode tap user "''${SUDO_USER:-$USER}"
    else
      echo "  $TAP_NAME already exists"
    fi

    # Configure IP address
    echo "  Configuring IP address $HOST_IP/${netmask}..."
    ip addr flush dev "$TAP_NAME" 2>/dev/null || true
    ip addr add "$HOST_IP/${netmask}" dev "$TAP_NAME"

    # Bring interface up
    echo "  Bringing interface up..."
    ip link set "$TAP_NAME" up

    # Enable IP forwarding
    echo "  Enabling IP forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Set up NAT if we have an internet interface
    if [ -n "$DEFAULT_IFACE" ]; then
      echo "  Setting up NAT (masquerading) via $DEFAULT_IFACE..."

      # Add MASQUERADE rule if not already present
      if ! iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$DEFAULT_IFACE" -j MASQUERADE
      fi

      # Allow forwarding from TAP to internet
      if ! iptables -C FORWARD -i "$TAP_NAME" -o "$DEFAULT_IFACE" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "$TAP_NAME" -o "$DEFAULT_IFACE" -j ACCEPT
      fi

      # Allow return traffic
      if ! iptables -C FORWARD -i "$DEFAULT_IFACE" -o "$TAP_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "$DEFAULT_IFACE" -o "$TAP_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT
      fi
    fi

    echo ""
    echo "Network setup complete!"
    echo ""
    echo "Host configuration:"
    echo "  Interface: $TAP_NAME"
    echo "  IP: $HOST_IP/${netmask}"
    ip link show "$TAP_NAME" | head -2
    echo ""
    echo "Guest should use:"
    echo "  IP: ${guestIp}/${netmask}"
    echo "  Gateway: $HOST_IP"
    echo "  DNS: 1.1.1.1 or 8.8.8.8"
    echo ""
    echo "To run Redox with networking:"
    echo "  nix run .#run-redox-cloud-hypervisor-net"
    echo ""
    echo "To tear down (cleanup):"
    echo "  sudo ip link delete $TAP_NAME"
  '';

  # Headless Cloud Hypervisor runner with serial console (no networking)
  # Performance optimized with direct I/O and CPU topology
  headless = pkgs.writeShellScriptBin "run-redox-cloud-hypervisor" ''
    set -e

    # Environment variable overrides for customization
    CH_CPUS="''${CH_CPUS:-${defaultCpus}}"
    CH_MEMORY="''${CH_MEMORY:-${defaultMemory}}"
    CH_HUGEPAGES="''${CH_HUGEPAGES:-}"
    CH_DIRECT_IO="''${CH_DIRECT_IO:-on}"

    # Create writable copies
    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR" EXIT

    IMAGE="$WORK_DIR/redox.img"
    FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"

    echo "Copying disk image to $WORK_DIR..."
    cp ${diskImage}/redox.img "$IMAGE"
    chmod +w "$IMAGE"

    # Build disk options
    DISK_OPTS="path=$IMAGE"
    if [ "$CH_DIRECT_IO" = "on" ]; then
      DISK_OPTS="$DISK_OPTS,direct=on"
    fi

    # Build memory options
    MEMORY_OPTS="size=$CH_MEMORY"
    if [ -n "$CH_HUGEPAGES" ]; then
      MEMORY_OPTS="$MEMORY_OPTS,hugepages=on"
    fi

    echo "Starting Redox OS with Cloud Hypervisor..."
    echo ""
    echo "Firmware: $FIRMWARE"
    echo "Disk: $IMAGE"
    echo ""
    echo "Configuration:"
    echo "  CPUs: $CH_CPUS (topology: ${cpuTopology})"
    echo "  Memory: $CH_MEMORY''${CH_HUGEPAGES:+ (hugepages enabled)}"
    echo "  Direct I/O: $CH_DIRECT_IO"
    echo ""
    echo "Requirements:"
    echo "  - KVM enabled (/dev/kvm accessible)"
    echo "  ''${CH_HUGEPAGES:+- Huge pages allocated on host}"
    echo ""
    echo "Environment overrides:"
    echo "  CH_CPUS=N       - Number of vCPUs (default: ${defaultCpus})"
    echo "  CH_MEMORY=SIZE  - Memory size (default: ${defaultMemory})"
    echo "  CH_HUGEPAGES=1  - Enable huge pages"
    echo "  CH_DIRECT_IO=on|off - Direct I/O bypass (default: on)"
    echo ""
    echo "Controls:"
    echo "  Ctrl+C: Quit Cloud Hypervisor"
    echo ""
    echo "Network: Disabled (use run-redox-cloud-hypervisor-net for networking)"
    echo "Storage: virtio-blk with direct I/O"
    echo ""

    # Cloud Hypervisor UEFI boot with performance tuning:
    # - --firmware: CLOUDHV.fd for UEFI
    # - --disk: virtio-blk with direct=on for bypassing host page cache
    # - --cpus: boot count + topology for better guest scheduler decisions
    # - --memory: size + optional hugepages
    # - --platform: Configure PCI segments
    # - --pci-segment: Increase 32-bit MMIO aperture weight
    # - --serial: serial console to tty
    # - --console: disable virtio-console (we use serial)
    ${cloudHypervisor}/bin/cloud-hypervisor \
      --firmware "$FIRMWARE" \
      --disk "$DISK_OPTS" \
      --cpus boot="$CH_CPUS",topology=${cpuTopology} \
      --memory "$MEMORY_OPTS" \
      --platform num_pci_segments=1 \
      --pci-segment pci_segment=0,mmio32_aperture_weight=4 \
      --serial tty \
      --console off \
      "$@"
  '';

  # Cloud Hypervisor runner with TAP networking
  # Requires: NixOS cloud-hypervisor-host tag or manual TAP setup
  # Uses static IP configuration for fast boot (no DHCP dependency)
  # Performance optimized with direct I/O, CPU topology, and multi-queue networking
  withNetwork = pkgs.writeShellScriptBin "run-redox-cloud-hypervisor-net" ''
    set -e

    # Network configuration
    TAP_NAME="''${TAP_NAME:-${tapInterface}}"
    HOST_IP="''${HOST_IP:-${hostIp}}"
    GUEST_IP="''${GUEST_IP:-${guestIp}}"
    GUEST_MAC="''${GUEST_MAC:-${guestMac}}"

    # Environment variable overrides for customization
    CH_CPUS="''${CH_CPUS:-${defaultCpus}}"
    CH_MEMORY="''${CH_MEMORY:-${defaultMemory}}"
    CH_HUGEPAGES="''${CH_HUGEPAGES:-}"
    CH_DIRECT_IO="''${CH_DIRECT_IO:-on}"
    CH_NET_QUEUES="''${CH_NET_QUEUES:-${netQueues}}"
    CH_NET_QUEUE_SIZE="''${CH_NET_QUEUE_SIZE:-${netQueueSize}}"

    # Create work directory
    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR" EXIT

    IMAGE="$WORK_DIR/redox.img"
    FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"

    echo "Copying disk image to $WORK_DIR..."
    cp ${networkDiskImage}/redox.img "$IMAGE"
    chmod +w "$IMAGE"

    # Build disk options
    DISK_OPTS="path=$IMAGE"
    if [ "$CH_DIRECT_IO" = "on" ]; then
      DISK_OPTS="$DISK_OPTS,direct=on"
    fi

    # Build memory options
    MEMORY_OPTS="size=$CH_MEMORY"
    if [ -n "$CH_HUGEPAGES" ]; then
      MEMORY_OPTS="$MEMORY_OPTS,hugepages=on"
    fi

    # Check for TAP interface
    if ! ${pkgs.iproute2}/bin/ip link show "$TAP_NAME" &>/dev/null; then
      echo "TAP interface $TAP_NAME not found!"
      echo ""
      echo "This runner requires the NixOS cloud-hypervisor-host tag, which provides:"
      echo "  - TAP interface ($TAP_NAME) with IP $HOST_IP/${netmask}"
      echo "  - DHCP server (dnsmasq) for automatic guest IP assignment"
      echo "  - NAT/masquerading for internet access"
      echo ""
      echo "Add 'cloud-hypervisor-host' tag to your machine in onix-core:"
      echo "  inventory/core/machines.nix"
      echo ""
      echo "Then rebuild: clan machines update <machine>"
      echo ""
      exit 1
    fi

    # Verify TAP interface has an IP address (required for guest connectivity)
    if ! ${pkgs.iproute2}/bin/ip addr show "$TAP_NAME" | ${pkgs.gnugrep}/bin/grep -q "inet "; then
      echo "WARNING: TAP interface $TAP_NAME has no IP address assigned!"
      echo ""
      echo "Assigning $HOST_IP/${netmask} to $TAP_NAME..."
      if ${pkgs.iproute2}/bin/ip addr add "$HOST_IP/${netmask}" dev "$TAP_NAME" 2>/dev/null; then
        echo "IP assigned successfully."
      else
        echo "Failed to assign IP. Try running manually:"
        echo "  sudo ip addr add $HOST_IP/${netmask} dev $TAP_NAME"
        echo ""
        echo "The guest will not have network connectivity without this."
      fi
    fi

    echo "Starting Redox OS with Cloud Hypervisor (networked)..."
    echo ""
    echo "Firmware: $FIRMWARE"
    echo "Disk: $IMAGE"
    echo ""
    echo "Configuration:"
    echo "  CPUs: $CH_CPUS (topology: ${cpuTopology})"
    echo "  Memory: $CH_MEMORY''${CH_HUGEPAGES:+ (hugepages enabled)}"
    echo "  Direct I/O: $CH_DIRECT_IO"
    echo "  Network queues: $CH_NET_QUEUES (queue size: $CH_NET_QUEUE_SIZE)"
    echo ""
    echo "Network Configuration:"
    echo "  TAP interface: $TAP_NAME"
    echo "  Guest MAC: $GUEST_MAC"
    echo "  Guest IP: $GUEST_IP/${netmask} (static config)"
    echo "  Gateway: $HOST_IP"
    echo "  DNS: 1.1.1.1, 8.8.8.8"
    echo ""
    echo "Environment overrides:"
    echo "  CH_CPUS=N            - Number of vCPUs (default: ${defaultCpus})"
    echo "  CH_MEMORY=SIZE       - Memory size (default: ${defaultMemory})"
    echo "  CH_HUGEPAGES=1       - Enable huge pages"
    echo "  CH_DIRECT_IO=on|off  - Direct I/O bypass (default: on)"
    echo "  CH_NET_QUEUES=N      - Network queues (default: ${netQueues})"
    echo "  CH_NET_QUEUE_SIZE=N  - Queue size (default: ${netQueueSize})"
    echo ""
    echo "Network will be configured at boot with static IP."
    echo ""
    echo "Controls:"
    echo "  Ctrl+C: Quit Cloud Hypervisor"
    echo ""

    # Cloud Hypervisor with virtio-net (multi-queue for parallel packet processing):
    # - --disk: virtio-blk with direct=on for bypassing host page cache
    # - --cpus: boot count + topology for better guest scheduler decisions
    # - --memory: size + optional hugepages
    # - --net: TAP with multi-queue (num_queues + queue_size) for throughput
    # - MAC address helps guest identify the interface
    ${cloudHypervisor}/bin/cloud-hypervisor \
      --firmware "$FIRMWARE" \
      --disk "$DISK_OPTS" \
      --cpus boot="$CH_CPUS",topology=${cpuTopology} \
      --memory "$MEMORY_OPTS" \
      --platform num_pci_segments=1 \
      --pci-segment pci_segment=0,mmio32_aperture_weight=4 \
      --net tap="$TAP_NAME",mac="$GUEST_MAC",num_queues="$CH_NET_QUEUES",queue_size="$CH_NET_QUEUE_SIZE" \
      --serial tty \
      --console off \
      "$@"
  '';

  # Development mode runner with API socket for runtime control
  # Enables pause/resume, snapshot/restore, and runtime monitoring
  withDev = pkgs.writeShellScriptBin "run-redox-cloud-hypervisor-dev" ''
    set -e

    # Environment variable overrides for customization
    CH_CPUS="''${CH_CPUS:-${defaultCpus}}"
    CH_MEMORY="''${CH_MEMORY:-${defaultMemory}}"
    CH_HUGEPAGES="''${CH_HUGEPAGES:-}"
    CH_DIRECT_IO="''${CH_DIRECT_IO:-on}"
    CH_API_SOCKET="''${CH_API_SOCKET:-${defaultApiSocket}}"

    # Create writable copies
    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR; rm -f $CH_API_SOCKET" EXIT

    IMAGE="$WORK_DIR/redox.img"
    FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"

    echo "Copying disk image to $WORK_DIR..."
    cp ${diskImage}/redox.img "$IMAGE"
    chmod +w "$IMAGE"

    # Build disk options
    DISK_OPTS="path=$IMAGE"
    if [ "$CH_DIRECT_IO" = "on" ]; then
      DISK_OPTS="$DISK_OPTS,direct=on"
    fi

    # Build memory options with hotplug support for development
    MEMORY_OPTS="size=$CH_MEMORY,hotplug_method=virtio-mem,hotplug_size=2048M"
    if [ -n "$CH_HUGEPAGES" ]; then
      MEMORY_OPTS="size=$CH_MEMORY,hugepages=on,hotplug_method=virtio-mem,hotplug_size=2048M"
    fi

    echo "Starting Redox OS with Cloud Hypervisor (development mode)..."
    echo ""
    echo "Firmware: $FIRMWARE"
    echo "Disk: $IMAGE"
    echo "API Socket: $CH_API_SOCKET"
    echo ""
    echo "Configuration:"
    echo "  CPUs: $CH_CPUS (topology: ${cpuTopology})"
    echo "  Memory: $CH_MEMORY + 2048M hotplug''${CH_HUGEPAGES:+ (hugepages enabled)}"
    echo "  Direct I/O: $CH_DIRECT_IO"
    echo ""
    echo "Requirements:"
    echo "  - KVM enabled (/dev/kvm accessible)"
    echo "  ''${CH_HUGEPAGES:+- Huge pages allocated on host}"
    echo ""
    echo "Runtime control via ch-remote:"
    echo "  Pause:    ch-remote --api-socket=$CH_API_SOCKET pause"
    echo "  Resume:   ch-remote --api-socket=$CH_API_SOCKET resume"
    echo "  Snapshot: ch-remote --api-socket=$CH_API_SOCKET snapshot file:///path"
    echo "  Info:     ch-remote --api-socket=$CH_API_SOCKET info"
    echo ""
    echo "Or use the wrapper scripts:"
    echo "  nix run .#pause-redox"
    echo "  nix run .#resume-redox"
    echo "  nix run .#snapshot-redox -- /path/to/snapshot"
    echo ""
    echo "Controls:"
    echo "  Ctrl+C: Quit Cloud Hypervisor"
    echo ""

    # Cloud Hypervisor with API socket for runtime control:
    # - --api-socket: Enables pause/resume, snapshot/restore, hotplug
    # - --memory: Includes virtio-mem hotplug for dynamic memory
    ${cloudHypervisor}/bin/cloud-hypervisor \
      --firmware "$FIRMWARE" \
      --disk "$DISK_OPTS" \
      --cpus boot="$CH_CPUS",topology=${cpuTopology} \
      --memory "$MEMORY_OPTS" \
      --platform num_pci_segments=1 \
      --pci-segment pci_segment=0,mmio32_aperture_weight=4 \
      --api-socket path="$CH_API_SOCKET" \
      --serial tty \
      --console off \
      "$@"
  '';

  # ch-remote wrapper: Pause VM
  pauseVm = pkgs.writeShellScriptBin "pause-redox" ''
    CH_API_SOCKET="''${CH_API_SOCKET:-${defaultApiSocket}}"
    if [ ! -S "$CH_API_SOCKET" ]; then
      echo "API socket not found: $CH_API_SOCKET"
      echo "Make sure the VM is running with: nix run .#run-redox-cloud-hypervisor-dev"
      exit 1
    fi
    echo "Pausing VM..."
    ${cloudHypervisor}/bin/ch-remote --api-socket="$CH_API_SOCKET" pause
    echo "VM paused."
  '';

  # ch-remote wrapper: Resume VM
  resumeVm = pkgs.writeShellScriptBin "resume-redox" ''
    CH_API_SOCKET="''${CH_API_SOCKET:-${defaultApiSocket}}"
    if [ ! -S "$CH_API_SOCKET" ]; then
      echo "API socket not found: $CH_API_SOCKET"
      echo "Make sure the VM is running with: nix run .#run-redox-cloud-hypervisor-dev"
      exit 1
    fi
    echo "Resuming VM..."
    ${cloudHypervisor}/bin/ch-remote --api-socket="$CH_API_SOCKET" resume
    echo "VM resumed."
  '';

  # ch-remote wrapper: Snapshot VM
  snapshotVm = pkgs.writeShellScriptBin "snapshot-redox" ''
    CH_API_SOCKET="''${CH_API_SOCKET:-${defaultApiSocket}}"
    SNAPSHOT_DIR="''${1:-/tmp/redox-snapshot}"

    if [ ! -S "$CH_API_SOCKET" ]; then
      echo "API socket not found: $CH_API_SOCKET"
      echo "Make sure the VM is running with: nix run .#run-redox-cloud-hypervisor-dev"
      exit 1
    fi

    echo "Creating snapshot directory: $SNAPSHOT_DIR"
    mkdir -p "$SNAPSHOT_DIR"

    echo "Pausing VM..."
    ${cloudHypervisor}/bin/ch-remote --api-socket="$CH_API_SOCKET" pause

    echo "Taking snapshot to $SNAPSHOT_DIR..."
    ${cloudHypervisor}/bin/ch-remote --api-socket="$CH_API_SOCKET" snapshot "file://$SNAPSHOT_DIR"

    echo "Snapshot saved to: $SNAPSHOT_DIR"
    echo ""
    echo "To restore, start a new Cloud Hypervisor instance and run:"
    echo "  ch-remote --api-socket=<socket> restore source_url=file://$SNAPSHOT_DIR"
    echo ""
    echo "VM is still paused. Resume with: nix run .#resume-redox"
  '';

  # ch-remote wrapper: VM info
  infoVm = pkgs.writeShellScriptBin "info-redox" ''
    CH_API_SOCKET="''${CH_API_SOCKET:-${defaultApiSocket}}"
    if [ ! -S "$CH_API_SOCKET" ]; then
      echo "API socket not found: $CH_API_SOCKET"
      echo "Make sure the VM is running with: nix run .#run-redox-cloud-hypervisor-dev"
      exit 1
    fi
    ${cloudHypervisor}/bin/ch-remote --api-socket="$CH_API_SOCKET" info
  '';

  # ch-remote wrapper: Resize memory (virtio-mem hotplug)
  resizeMemory = pkgs.writeShellScriptBin "resize-memory-redox" ''
    CH_API_SOCKET="''${CH_API_SOCKET:-${defaultApiSocket}}"
    NEW_SIZE="''${1:-}"

    if [ -z "$NEW_SIZE" ]; then
      echo "Usage: resize-memory-redox <size_in_bytes>"
      echo "Example: resize-memory-redox 3221225472  # 3GB"
      exit 1
    fi

    if [ ! -S "$CH_API_SOCKET" ]; then
      echo "API socket not found: $CH_API_SOCKET"
      echo "Make sure the VM is running with: nix run .#run-redox-cloud-hypervisor-dev"
      exit 1
    fi

    echo "Resizing VM memory to $NEW_SIZE bytes..."
    ${cloudHypervisor}/bin/ch-remote --api-socket="$CH_API_SOCKET" resize --memory "$NEW_SIZE"
    echo "Memory resize requested. Guest OS must support virtio-mem."
  '';
}
