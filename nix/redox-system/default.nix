# RedoxOS Module System - Adios-Based Entry Point
#
# Uses the adios module system with korora types.
#
# Architecture:
#   1. adios loads a tree of typed modules from ./modules/
#   2. Each module declares options (korora-typed), inputs (explicit deps), and impl
#   3. Profiles are option presets applied via initial options or .override
#   4. The /build module reads all config and produces diskImage, initfs, rootTree
#
# Adios calling convention:
#   loadFn = adios moduleDefinition;     # Returns a load function
#   treeNode = loadFn { options = {...}; };  # Evaluate tree with options
#   result = treeNode {};                 # Call root impl → get output
#   updated = treeNode.override { options = {...}; };  # Change options
#
# Example:
#   factory = import ./nix/redox-system { inherit lib; };
#   sys = factory.redoxSystem { modules = [ ./profiles/dev.nix ]; pkgs = ...; hostPkgs = ...; };
#   sys.diskImage  # the disk image derivation

{ lib }:

let
  # Import the adios module system (vendored)
  adios = import ../vendor/adios;

  # Root module definition
  rootModule = adios: {
    name = "redox-system";

    # Auto-import all modules from ./modules/
    # Creates: /pkgs, /boot, /hardware, /networking, /environment,
    #          /filesystem, /graphics, /services, /users, /build
    modules = adios.lib.importModules ./modules;

    # Root depends on the build module
    inputs = {
      build = {
        path = "/build";
      };
    };

    # Root impl: call the build module and return its outputs
    # (inputs.build gives us /build's OPTIONS, but /build has no user-facing options,
    #  so we need to call the build module node via __functor to get the impl output)
    impl =
      { inputs }:
      {
        # These are placeholders — actual derivations come from calling the
        # build module node in redoxSystem below
      };
  };

  # The main redoxSystem builder
  redoxSystem =
    {
      # List of profile paths, functions, or override attrsets
      modules ? [ ],
      # Flat attrset of all cross-compiled Redox packages
      pkgs,
      # nixpkgs for the build machine
      hostPkgs,
      # Extra arguments (kept for API compat)
      extraSpecialArgs ? { },
    }:
    let
      # Resolve a profile module to an override attrset
      resolveProfile =
        mod:
        if builtins.isAttrs mod then
          mod
        else if builtins.isFunction mod then
          mod { inherit pkgs lib; }
        else if builtins.isPath mod || builtins.isString mod then
          import mod { inherit pkgs lib; }
        else
          throw "redoxSystem: module must be an attrset, function, or path";

      # Merge all profile overrides (later wins on conflict)
      mergedProfiles = builtins.foldl' (acc: mod: acc // (resolveProfile mod)) { } modules;

      # Build the initial options: package injection + profile overrides
      initialOptions = {
        "/pkgs" = {
          inherit pkgs hostPkgs;
          nixpkgsLib = lib;
        };
      }
      // mergedProfiles;

      # Load the adios tree with all options
      loadFn = adios (rootModule adios);
      treeNode = loadFn { options = initialOptions; };

      # Call the build module to get derivations
      # The build module's impl produces { rootTree, initfs, diskImage }
      buildOutput = treeNode.modules.build { };

    in
    {
      # Core outputs
      diskImage = buildOutput.diskImage;
      initfs = buildOutput.initfs;
      toplevel = buildOutput.toplevel;
      rootTree = buildOutput.rootTree;

      # Composable partition images (for debugging/reuse)
      espImage = buildOutput.espImage;
      redoxfsImage = buildOutput.redoxfsImage;

      # Validation & metadata
      systemChecks = buildOutput.systemChecks;
      version = buildOutput.version;

      # Wrappers-style chainable extension
      extend =
        extraModule:
        let
          overrides =
            if builtins.isAttrs extraModule then
              extraModule
            else if builtins.isFunction extraModule then
              extraModule { inherit pkgs lib; }
            else
              import extraModule { inherit pkgs lib; };
        in
        redoxSystem {
          modules = modules ++ [ overrides ];
          inherit pkgs hostPkgs extraSpecialArgs;
        };

      # Type metadata
      _type = "redox-system";
      _module = {
        inherit modules pkgs hostPkgs;
      };
    };

in
{
  inherit redoxSystem;
  version = "0.3.0";
}
