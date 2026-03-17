{
  description = "Minimal Redox OS — bare shell + coreutils";

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
      apps.${system}.default = {
        type = "app";
        program = "${qemuRunners.headless}/bin/run-redox";
      };

      packages.${system}.default = mySystem.diskImage;
    };
}
