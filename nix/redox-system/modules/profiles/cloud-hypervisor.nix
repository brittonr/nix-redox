# Cloud Hypervisor RedoxOS Profile
#
# Optimized for running in Cloud Hypervisor with TAP networking.
# Uses static network config (no DHCP) for fast boot.
# Imports development profile for CLI tools.
#
# Usage:
#   redoxSystem { modules = [ ./profiles/cloud-hypervisor.nix ]; }

{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./development.nix ];

  # Static networking for Cloud Hypervisor TAP
  redox.networking = {
    mode = "static";
    interfaces.cloud-hypervisor = {
      address = "172.16.0.2";
      netmask = "255.255.255.0";
      gateway = "172.16.0.1";
    };
  };

  # VirtIO drivers only (no need for legacy drivers in CH)
  redox.hardware.storage.drivers = [ "virtio-blkd" ];
  redox.hardware.network.drivers = [ "virtio-netd" ];
}
