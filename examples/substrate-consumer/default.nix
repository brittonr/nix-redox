# External-consumer fixture for the public Redox substrate surface.
#
# Usage from a downstream flake:
#   import ./examples/substrate-consumer {
#     redoxSubstrate = redox.legacyPackages.${system}.redoxSubstrate;
#   }

{ redoxSubstrate }:

let
  plan = import ./primitive-plan.nix;
in
redoxSubstrate.builders.buildSystem { inherit plan; }
