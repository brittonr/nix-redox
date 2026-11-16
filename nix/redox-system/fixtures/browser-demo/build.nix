{ input ? "first" }:
derivation {
  name = "browser-demo-message";
  system = "x86_64-unknown-redox";
  builder = "/nix/system/profile/bin/bash";
  args = [ "--noprofile" "--norc" ./builder.sh ];
  # A declared derivation input, not a host environment read. It participates
  # in the derivation/output hash and is the only value the builder prints.
  message = input;
}
