{
  description = "My custom Redox OS configuration";

  inputs = {
    redox.url = "github:brittonr/redox";
  };

  outputs =
    { self, redox }:
    let
      system = "x86_64-linux";
      redoxLib = redox.legacyPackages.${system};

      # Build the system from our configuration
      mySystem = redoxLib.mkRedoxSystem {
        modules = [ ./configuration.nix ];
      };

      # Create VM runners
      runners = redoxLib.mkQemuRunners {
        inherit (mySystem) diskImage vmConfig;
      };
    in
    {
      # `nix run` boots the graphical desktop
      apps.${system}.default = {
        type = "app";
        program = "${runners.graphical}/bin/run-redox-graphical";
      };

      # `nix run .#headless` for serial console
      apps.${system}.headless = {
        type = "app";
        program = "${runners.headless}/bin/run-redox";
      };

      # `nix build` produces the disk image
      packages.${system}.default = mySystem.diskImage;
    };
}
