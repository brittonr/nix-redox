# Cloud Hypervisor runner scripts for RedoxOS
#
# Provides scripts for running Redox in Cloud Hypervisor:
# - headless: Serial console mode (no networking)
# - withNetwork: TAP networking mode with full connectivity + DHCP
# - setupNetwork: Helper script for host TAP/NAT configuration
#
# Cloud Hypervisor is a Rust-based VMM using virtio devices:
# - virtio-blk for storage
# - virtio-net for networking
# - CLOUDHV.fd firmware
#
# RedoxOS boots fully in Cloud Hypervisor with modern virtio support.
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

  # Use default disk image (with DHCP client) - DHCP server is provided by NixOS service
  networkDiskImage = diskImage;
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
  headless = pkgs.writeShellScriptBin "run-redox-cloud-hypervisor" ''
    set -e

    # Create writable copies
    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR" EXIT

    IMAGE="$WORK_DIR/redox.img"
    FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"

    echo "Copying disk image to $WORK_DIR..."
    cp ${diskImage}/redox.img "$IMAGE"
    chmod +w "$IMAGE"

    echo "Starting Redox OS with Cloud Hypervisor..."
    echo ""
    echo "Firmware: $FIRMWARE"
    echo "Disk: $IMAGE"
    echo ""
    echo "Requirements:"
    echo "  - KVM enabled (/dev/kvm accessible)"
    echo ""
    echo "Controls:"
    echo "  Ctrl+C: Quit Cloud Hypervisor"
    echo ""
    echo "Network: Disabled (use run-redox-cloud-hypervisor-net for networking)"
    echo "Storage: virtio-blk"
    echo ""
    echo "Note: Cloud Hypervisor's UEFI boot expects the bootloader to be"
    echo "      on the disk's ESP partition, not passed via --kernel."
    echo ""

    # Cloud Hypervisor UEFI boot:
    # - --firmware: CLOUDHV.fd for UEFI
    # - --disk: virtio-blk disk with GPT/ESP containing bootloader
    # - --platform: Configure PCI segments
    # - --pci-segment: Increase 32-bit MMIO aperture weight
    # - --serial: serial console to tty
    # - --console: disable virtio-console (we use serial)
    ${cloudHypervisor}/bin/cloud-hypervisor \
      --firmware "$FIRMWARE" \
      --disk path="$IMAGE" \
      --cpus boot=4 \
      --memory size=2048M \
      --platform num_pci_segments=1 \
      --pci-segment pci_segment=0,mmio32_aperture_weight=4 \
      --serial tty \
      --console off \
      "$@"
  '';

  # Cloud Hypervisor runner with TAP networking
  # Requires: NixOS cloud-hypervisor-host tag or manual TAP setup
  # DHCP server (dnsmasq) should be configured on the host
  withNetwork = pkgs.writeShellScriptBin "run-redox-cloud-hypervisor-net" ''
    set -e

    # Network configuration
    TAP_NAME="''${TAP_NAME:-${tapInterface}}"
    HOST_IP="''${HOST_IP:-${hostIp}}"
    GUEST_IP="''${GUEST_IP:-${guestIp}}"
    GUEST_MAC="''${GUEST_MAC:-${guestMac}}"

    # Create work directory
    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR" EXIT

    IMAGE="$WORK_DIR/redox.img"
    FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"

    echo "Copying disk image to $WORK_DIR..."
    cp ${networkDiskImage}/redox.img "$IMAGE"
    chmod +w "$IMAGE"

    # Check for TAP interface
    if ! ip link show "$TAP_NAME" &>/dev/null; then
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

    echo "Starting Redox OS with Cloud Hypervisor (networked)..."
    echo ""
    echo "Firmware: $FIRMWARE"
    echo "Disk: $IMAGE"
    echo ""
    echo "Network Configuration:"
    echo "  TAP interface: $TAP_NAME"
    echo "  Guest MAC: $GUEST_MAC"
    echo "  Guest IP: $GUEST_IP/${netmask} (via DHCP)"
    echo "  Gateway: $HOST_IP"
    echo "  DNS: 1.1.1.1, 8.8.8.8"
    echo ""
    echo "Network will be automatically configured at boot via DHCP."
    echo ""
    echo "Controls:"
    echo "  Ctrl+C: Quit Cloud Hypervisor"
    echo ""

    # Cloud Hypervisor with virtio-net:
    # - --net: TAP interface with explicit MAC address
    # - MAC address helps guest identify the interface
    ${cloudHypervisor}/bin/cloud-hypervisor \
      --firmware "$FIRMWARE" \
      --disk path="$IMAGE" \
      --cpus boot=4 \
      --memory size=2048M \
      --platform num_pci_segments=1 \
      --pci-segment pci_segment=0,mmio32_aperture_weight=4 \
      --net tap="$TAP_NAME",mac="$GUEST_MAC" \
      --serial tty \
      --console off \
      "$@"
  '';
}
