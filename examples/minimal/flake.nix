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

      chRunners = redoxLib.mkCloudHypervisorRunners {
        inherit (mySystem) diskImage vmConfig;
      };
    in
    {
      apps.${system}.default = {
        type = "app";
        program = "${chRunners.headless}/bin/run-redox-cloud-hypervisor";
      };

      packages.${system}.default = mySystem.diskImage;
    };
}
