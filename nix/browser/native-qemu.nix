# Keep the upstream recipe intact: numbered patches, Meson wrap hashes, and
# -DQEMU_GENERIC_HOST_TICKS are part of migration compatibility.
{ pkgs, trynixSource }: import (trynixSource + "/nix/native-qemu.nix") { inherit pkgs; }
