# Source patching module for RedoxOS
#
# This module applies patches to upstream sources fetched via flake inputs.
# Use this for maintaining local fixes while tracking upstream.
#
# Usage:
#   Patches are applied to sources and exposed via patchedSources.
#   Other modules can access patchedSources.base, patchedSources.kernel, etc.

{ inputs, ... }:

{
  perSystem =
    { pkgs, lib, ... }:
    {
      _module.args.patchedSources = {
        # Patched base source with Cloud Hypervisor support
        # These patches add:
        # - BAR size probing workaround for virtio devices
        # - Modern virtio device ID support
        # - Increased BAR sizes for Cloud Hypervisor compatibility
        base = pkgs.applyPatches {
          name = "base-patched";
          src = inputs.base-src;
          patches = [
            ../patches/base/0001-cloud-hypervisor-support.patch
            ../patches/base/0002-usb-initfs-driver-paths.patch
          ];
        };
      };
    };
}
