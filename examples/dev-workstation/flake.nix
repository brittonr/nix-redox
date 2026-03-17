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
        # `nix run` — headless with serial console (QEMU)
        default = {
          type = "app";
          program = "${qemuRunners.headless}/bin/run-redox";
        };

        # `nix run .#cloud-hypervisor` — fast headless (no interactive serial)
        cloud-hypervisor = {
          type = "app";
          program = "${chRunners.headless}/bin/run-redox-cloud-hypervisor";
        };
      };

      packages.${system}.default = mySystem.diskImage;
    };
}
