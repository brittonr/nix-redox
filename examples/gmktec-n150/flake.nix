{
  description = "Redox OS for GMKtec N150 — bare metal boot (base + self-hosting)";

  inputs = {
    redox.url = "path:../../";
  };

  outputs =
    { self, redox }:
    let
      system = "x86_64-linux";
      redoxLib = redox.legacyPackages.${system};

      base = redoxLib.mkRedoxSystem {
        modules = [ ./configuration.nix ];
      };

      selfHosting = redoxLib.mkRedoxSystem {
        modules = [ ./self-hosting.nix ];
      };

      baseRunners = redoxLib.mkQemuRunners {
        inherit (base) diskImage vmConfig;
      };

      shRunners = redoxLib.mkQemuRunners {
        inherit (selfHosting) diskImage vmConfig;
      };
    in
    {
      apps.${system} = {
        # `nix run` — base config, graphical QEMU
        default = {
          type = "app";
          program = "${baseRunners.graphical}/bin/run-redox-graphical";
        };

        # `nix run .#headless` — base config, serial console
        headless = {
          type = "app";
          program = "${baseRunners.headless}/bin/run-redox";
        };

        # `nix run .#self-hosting` — self-hosting config, graphical QEMU
        self-hosting = {
          type = "app";
          program = "${shRunners.graphical}/bin/run-redox-graphical";
        };

        # `nix run .#self-hosting-headless` — self-hosting, serial console
        self-hosting-headless = {
          type = "app";
          program = "${shRunners.headless}/bin/run-redox";
        };
      };

      packages.${system} = {
        default = base.diskImage;
        self-hosting = selfHosting.diskImage;
      };
    };
}
