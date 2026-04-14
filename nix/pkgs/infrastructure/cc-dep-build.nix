derivation {
  name = "cc-dep-test";
  builder = "/nix/system/profile/bin/bash";
  args = [ "--noprofile" "--norc" "/usr/src/cc-dep-test/build-cc-dep.sh" ];
  system = "x86_64-unknown-redox";
}
