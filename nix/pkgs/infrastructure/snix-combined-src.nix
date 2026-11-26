# Single source tree for the host cross-build, the guest source bundle, and
# the host unit tests. Keeping one derivation means a source or upstream-patch
# change cannot reach one build path without the others.
{ pkgs, snix-redox-src }:

let
  snixUpstreamSource = import ./snix-upstream-source.nix { inherit pkgs; };
in
pkgs.runCommand "snix-redox-combined-src" { } ''
  cp -r ${snix-redox-src} $out
  chmod -R u+w $out
  rm -f $out/upstream
  cp -r ${snixUpstreamSource} $out/upstream
''
