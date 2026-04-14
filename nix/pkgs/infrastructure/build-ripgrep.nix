derivation {
  name = "ripgrep-on-redox";
  system = "x86_64-unknown-redox";
  builder = "/nix/system/profile/bin/bash";
  args = [ "--noprofile" "--norc" "/usr/src/ripgrep/build-ripgrep.sh" ];
}
