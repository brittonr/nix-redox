# Flake module for downstream composition
#
# Import this in a flake-parts or adios-flake consumer to get
# a `redoxConfigurations` flake output option.
#
# Usage:
#   {
#     imports = [ redox.flakeModules.default ];
#     flake.redoxConfigurations.myDevice = redox.lib.redoxSystem { ... };
#   }
{
  lib,
  ...
}:
{
  options.flake.redoxConfigurations = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.raw;
    default = { };
    description = "Redox OS system configurations";
  };
}
