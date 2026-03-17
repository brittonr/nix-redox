{
  description = "Graphical Redox OS — Orbital desktop environment";

  inputs = {
    redox.url = "github:brittonr/nix-redox";
  };

  outputs =
    { self, redox }:
    let
      system = "x86_64-linux";
      redoxLib = redox.legacyPackages.${system};

      mySystem = redoxLib.mkRedoxSystem {
        modules = [ ./configuration.nix ];
      };

      qemuRunners = redoxLib.mkQemuRunners {
        inherit (mySystem) diskImage vmConfig;
      };
    in
    {
      apps.${system} = {
        # `nix run` — graphical desktop (QEMU + GTK)
        default = {
          type = "app";
          program = "${qemuRunners.graphical}/bin/run-redox-graphical";
        };

        # `nix run .#headless` — serial console (QEMU, no display)
        headless = {
          type = "app";
          program = "${qemuRunners.headless}/bin/run-redox";
        };
      };

      packages.${system}.default = mySystem.diskImage;
    };
}
