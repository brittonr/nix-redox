{
  snix = derivation {
    name = "snix";
    builder = "/nix/system/profile/bin/bash";
    args = [ "-c" "/bin/mkdir -p $out/bin; /bin/cp @OUTPUT@/bin/snix $out/bin/snix; /bin/chmod +x $out/bin/snix" ];
    system = "x86_64-unknown-redox";
  };
}
