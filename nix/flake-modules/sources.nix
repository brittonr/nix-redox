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
          ];
          postPatch = ''
            # Fix USB sub-driver paths for initfs boot.
            # xhcid embeds drivers.toml at compile time via include_bytes! and prepends
            # /usr/lib/drivers/ to relative command paths. During initfs boot that path
            # doesn't exist -- binaries live at /scheme/initfs/lib/drivers/.
            # Using absolute paths makes xhcid's starts_with('/') check preserve them.
            substituteInPlace drivers/usb/xhcid/drivers.toml \
              --replace-fail 'command = ["usbhubd"' 'command = ["/scheme/initfs/lib/drivers/usbhubd"' \
              --replace-fail 'command = ["usbhidd"' 'command = ["/scheme/initfs/lib/drivers/usbhidd"'
          '';
        };
      };
    };
}
