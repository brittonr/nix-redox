# Cloud Hypervisor runner scripts for RedoxOS
#
# Provides scripts for running Redox in Cloud Hypervisor:
# - headless: Serial console mode
# - withNetwork: TAP networking mode
#
# Cloud Hypervisor is a Rust-based VMM using virtio devices:
# - virtio-blk for storage
# - virtio-net for networking
# - CLOUDHV.fd firmware
#
# RedoxOS boots fully in Cloud Hypervisor with modern virtio support.

{
  pkgs,
  lib,
  diskImage,
}:

let
  cloudHypervisor = pkgs.cloud-hypervisor;
  cloudhvFirmware = pkgs.OVMF-cloud-hypervisor.fd;
in
{
  # Headless Cloud Hypervisor runner with serial console
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
    echo "Network: virtio-net (no SLIRP/NAT - requires TAP or vhost-user)"
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
  withNetwork = pkgs.writeShellScriptBin "run-redox-cloud-hypervisor-net" ''
    set -e

    # Create writable copies
    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR" EXIT

    IMAGE="$WORK_DIR/redox.img"
    FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"

    echo "Copying disk image to $WORK_DIR..."
    cp ${diskImage}/redox.img "$IMAGE"
    chmod +w "$IMAGE"

    # Check for TAP interface
    TAP_NAME="''${TAP_NAME:-tap0}"
    if ! ip link show "$TAP_NAME" &>/dev/null; then
      echo "TAP interface $TAP_NAME not found!"
      echo ""
      echo "To create a TAP interface, run as root:"
      echo "  sudo ip tuntap add dev $TAP_NAME mode tap user $USER"
      echo "  sudo ip link set $TAP_NAME up"
      echo "  sudo ip addr add 172.16.0.1/24 dev $TAP_NAME"
      echo ""
      echo "Or set TAP_NAME to an existing interface."
      exit 1
    fi

    echo "Starting Redox OS with Cloud Hypervisor (networked)..."
    echo ""
    echo "Firmware: $FIRMWARE"
    echo "Disk: $IMAGE"
    echo "TAP: $TAP_NAME"
    echo ""

    ${cloudHypervisor}/bin/cloud-hypervisor \
      --firmware "$FIRMWARE" \
      --disk path="$IMAGE" \
      --cpus boot=4 \
      --memory size=2048M \
      --platform num_pci_segments=1 \
      --pci-segment pci_segment=0,mmio32_aperture_weight=4 \
      --net tap="$TAP_NAME" \
      --serial tty \
      --console off \
      "$@"
  '';
}
