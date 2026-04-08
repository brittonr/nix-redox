# Nix derivation for building ripgrep on Redox OS.
# Usage on guest: snix build --file /usr/src/ripgrep/build.nix
derivation {
  name = "ripgrep-on-redox";
  system = "x86_64-unknown-redox";
  builder = "/nix/system/profile/bin/bash";
  args = [ "/usr/src/ripgrep/build-ripgrep.sh" ];
}
