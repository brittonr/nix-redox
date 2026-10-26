# Host staging only: every derivation evaluated by build.nix runs on Redox.
{
  pkgs,
  lib,
  initfsTools,
  nativeKernelRebuildBundle,
  nixpkgsLib,
  seedConfig,
  seedInputs,
  seedEtc,
  seedPackages,
  bootstrap,
  base,
  ion,
  redoxfsTarget,
  netutils ? null,
  userutils ? null,
}:
let
  seed = pkgs.writeText "native-system-seed.json" (builtins.toJSON {
    cfg = seedConfig;
    inputs = seedInputs;
    packages = seedPackages;
    # These identities remain part of every native derivation, even when the
    # bootstrap packages are provided through the initial system profile.
    bootstrapInputs = map toString (
      [ nativeKernelRebuildBundle seedEtc bootstrap base ion redoxfsTarget ]
      ++ map (p: p.storePath) seedPackages
      ++ lib.optional (netutils != null) netutils
      ++ lib.optional (userutils != null) userutils
    );
  });
in
pkgs.runCommand "native-system-source-bundle" { } ''
  mkdir -p $out/renderers $out/initfs-tools $out/packages $out/lib
  cp ${./native-system-build.nix} $out/build.nix
  cp ${./native-initfs-tools-build.nix} $out/tools.nix
  cp ${seed} $out/seed.json
  cp -r ${nixpkgsLib}/. $out/lib/
  cp ${../../redox-system/modules/build/init-scripts.nix} $out/renderers/init-scripts.nix
  cp ${../../redox-system/modules/build/pcid.nix} $out/renderers/pcid.nix
  cp ${../../redox-system/modules/build/initfs.nix} $out/renderers/initfs.nix
  cp -r ${seedEtc} $out/seed-etc
  cp -r ${initfsTools.initfsToolsSrc}/. $out/initfs-tools/
  cp -r ${initfsTools.mergedVendor} $out/initfs-tools/vendor
  cp -r ${base} $out/packages/base
  cp -r ${bootstrap} $out/packages/bootstrap
  cp -r ${ion} $out/packages/ion
  cp -r ${redoxfsTarget} $out/packages/redoxfs
  ${lib.optionalString (netutils != null) "cp -r ${netutils} $out/packages/netutils"}
  ${lib.optionalString (userutils != null) "cp -r ${userutils} $out/packages/userutils"}
''
