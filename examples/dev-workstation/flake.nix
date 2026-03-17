{
  description = "Redox OS dev workstation — headless with developer tools";

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
      qemuRunners = redoxLib.mkQemuRunners {
        inherit (mySystem) diskImage vmConfig;
      };
    in
    {
      apps.${system} = {
        # `nix run` — headless serial console (Cloud Hypervisor)
        default = {
          type = "app";
          program = "${chRunners.headless}/bin/run-redox-cloud-hypervisor";
        };

        # `nix run .#qemu` — headless serial console (QEMU)
        qemu = {
          type = "app";
          program = "${qemuRunners.headless}/bin/run-redox";
        };
      };

      packages.${system}.default = mySystem.diskImage;
    };
}
