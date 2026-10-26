# Nix derivation for rebuilding the Redox bootloader on a running Redox guest.
# Usage on guest: snix build --file /usr/src/native-kernel-rebuild/bootloader/build.nix

derivation {
  name = "redox-bootloader-native-rebuild";
  system = "x86_64-unknown-redox";
  builder = "/nix/system/profile/bin/bash";
  args = [ "--noprofile" "--norc" "${./.}/build-redox-bootloader.sh" ];
  source = ./.;
  rustSource = ../rust-src;
  bootstrapInputs = builtins.readFile ../bundle-manifest.json;
}
