{
  description = "My custom Redox OS configuration";

  inputs = {
    redox.url = "github:brittonr/nix-redox";
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

      # Create runners for both VMM backends
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

        # `nix run .#graphical` — explicit alias for default
        graphical = {
          type = "app";
          program = "${qemuRunners.graphical}/bin/run-redox-graphical";
        };

        # `nix run .#cloud-hypervisor` — headless Cloud Hypervisor
        cloud-hypervisor = {
          type = "app";
          program = "${chRunners.headless}/bin/run-redox-cloud-hypervisor";
        };
      };

      # `nix build` produces the disk image
      packages.${system}.default = mySystem.diskImage;
    };
}
