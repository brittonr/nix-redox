# Flake-parts module for RedoxOS apps
#
# This module provides runnable applications:
# - run-redox: Run Redox in QEMU (headless)
# - run-redox-graphical: Run Redox in QEMU (graphical)
# - build-cookbook: Run the cookbook/repo tool
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules/apps.nix ];
#
# Run apps:
#   nix run .#run-redox
#   nix run .#run-redox-graphical

{ self, inputs, ... }:

{
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    {
      apps = {
        run-redox = {
          type = "app";
          program = "${self'.packages.runQemu}/bin/run-redox";
        };

        run-redox-graphical = {
          type = "app";
          program = "${self'.packages.runQemuGraphical}/bin/run-redox-graphical";
        };

        build-cookbook = {
          type = "app";
          program = "${self'.packages.cookbook}/bin/repo";
        };
      };
    };
}
