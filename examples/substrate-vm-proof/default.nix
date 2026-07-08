# External-consumer fixture for the public Redox substrate VM proof surface.
# Consumers provide only the public substrate value.

{ redoxSubstrate }:

let
  plan = import ./primitive-plan.nix;
in
redoxSubstrate.builders.buildSystem { inherit plan; }
