# Nix derivation for self-compiling snix on Redox OS.
# Usage on guest: snix build --file /usr/src/snix-redox/build.nix
derivation {
  name = "snix-self-compiled";
  system = "x86_64-unknown-redox";
  builder = "/nix/system/profile/bin/bash";
  args = [ "/usr/src/snix-redox/build-snix.sh" ];
}
