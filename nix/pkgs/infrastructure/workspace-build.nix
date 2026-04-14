derivation {
  name = "workspace-test";
  builder = "/nix/system/profile/bin/bash";
  args = [ "--noprofile" "--norc" "/usr/src/workspace-test/build-workspace.sh" ];
  system = "x86_64-unknown-redox";
}
