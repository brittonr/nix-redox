# Cloud Hypervisor RedoxOS Profile
#
# Static networking + virtio-only drivers, built on development profile.
# Usage: redoxSystem { modules = [ ./profiles/cloud-hypervisor.nix ]; ... }

{ pkgs, lib }:

let
  dev = import ./development.nix { inherit pkgs lib; };
in
dev
// {
  "/networking" = (dev."/networking" or { }) // {
    mode = "static";
    interfaces = {
      cloud-hypervisor = {
        address = "172.16.0.2";
        netmask = "255.255.255.0";
        gateway = "172.16.0.1";
      };
    };
  };

  "/hardware" = (dev."/hardware" or { }) // {
    storageDrivers = [ "virtio-blkd" ];
    networkDrivers = [ "virtio-netd" ];
  };

  # Cloud Hypervisor specific VM config
  "/virtualisation" = (dev."/virtualisation" or { }) // {
    vmm = "cloud-hypervisor";
    tapNetworking = true;
    directIO = true;
  };
}
