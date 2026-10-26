# Nix derivation for rebuilding the Redox kernel on a running Redox guest.
# Usage on guest: snix build --file /usr/src/native-kernel-rebuild/kernel/build.nix

derivation {
  name = "redox-kernel-native-rebuild";
  system = "x86_64-unknown-redox";
  builder = "/nix/system/profile/bin/bash";
  args = [ "--noprofile" "--norc" "${./.}/build-redox-kernel.sh" ];
  source = ./.;
  rustSource = ../rust-src;
  bootstrapInputs = builtins.readFile ../bundle-manifest.json;
}
