# Package Injection Module (/pkgs)
#
# Provides cross-compiled Redox packages, host packages, and nixpkgs lib
# to all other modules via inputs. Also computes redoxLib helpers.
#
# This is analogous to adios-contrib's /nixpkgs module.
# Other modules access it via: inputs = { pkgs = { path = "/pkgs"; }; };
# Then use: inputs.pkgs.pkgs, inputs.pkgs.hostPkgs, inputs.pkgs.redoxLib

adios:

{
  name = "pkgs";

  options = {
    pkgs = {
      type = adios.types.attrs;
      default = { };
      description = "Cross-compiled Redox packages (kernel, base, ion, etc.)";
    };

    hostPkgs = {
      type = adios.types.attrs;
      default = { };
      description = "nixpkgs for the build machine (redoxfs, python, etc.)";
    };

    nixpkgsLib = {
      type = adios.types.attrs;
      default = { };
      description = "nixpkgs lib functions (concatStringsSep, etc.)";
    };
  };

  impl =
    { options }:
    let
      redoxLib = import ../lib.nix {
        lib = options.nixpkgsLib;
        pkgs = options.hostPkgs;
      };
    in
    options // { inherit redoxLib; };
}
