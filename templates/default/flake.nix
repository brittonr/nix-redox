{
  description = "My Redox OS system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    redox.url = "github:user/redox"; # TODO: update to your Redox flake URL
    redox.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, redox, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # Build the Redox system using the module system
      mySystem = redox.lib.redoxSystem {
        modules = [ ./configuration.nix ];
        pkgs = redox.packages.${system}; # Cross-compiled Redox packages
        hostPkgs = pkgs; # Build machine packages
      };
    in
    {
      packages.${system} = {
        default = mySystem.diskImage;
        diskImage = mySystem.diskImage;
        toplevel = mySystem.toplevel;
      };

      # Quick boot: nix run
      apps.${system}.default = {
        type = "app";
        program = toString (
          pkgs.writeShellScript "run-redox" ''
            ${pkgs.qemu}/bin/qemu-system-x86_64 \
              -M pc -cpu host -enable-kvm \
              -m 2048 -smp 4 \
              -bios ${pkgs.OVMF.fd}/FV/OVMF.fd \
              -drive file=${mySystem.diskImage}/redox.img,format=raw,if=none,id=disk0 \
              -device virtio-blk-pci,drive=disk0 \
              -serial stdio -nographic
          ''
        );
      };
    };
}
