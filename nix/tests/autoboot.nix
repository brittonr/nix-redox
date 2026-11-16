# Focused issue #7 checks. These evaluate the real /boot module and inspect
# real package feature declarations; they do not substitute for VM boot proof.
{
  pkgs,
  bootloader-src,
  bootloaderVariants,
}:

let
  adios = import ../vendor/adios;
  loadBoot = adios {
    name = "autoboot-test";
    modules = {
      boot = import ../redox-system/modules/boot.nix adios;
      pkgs = import ../redox-system/modules/pkgs.nix adios;
    };
  };

  evaluate =
    packages: options:
    let
      tree = loadBoot {
        options = {
          "/pkgs".pkgs = packages;
          "/boot" = options;
        };
      };
    in
    tree.modules.boot { };

  cases = [
    {
      name = "disk-manual";
      liveMode = false;
      autoBoot = false;
      variant = "bootloader";
      features = [ ];
    }
    {
      name = "disk-auto";
      liveMode = false;
      autoBoot = true;
      variant = "bootloaderAutoboot";
      features = [ "autoboot" ];
    }
    {
      name = "live-manual";
      liveMode = true;
      autoBoot = false;
      variant = "bootloaderLive";
      features = [ "live" ];
    }
    {
      name = "live-auto";
      liveMode = true;
      autoBoot = true;
      variant = "bootloaderLiveAutoboot";
      features = [
        "live"
        "autoboot"
      ];
    }
  ];

  matrix = builtins.map (
    case:
    let
      boot = evaluate bootloaderVariants { inherit (case) liveMode autoBoot; };
      expected = bootloaderVariants.${case.variant};
    in
    assert boot.liveMode == case.liveMode;
    assert boot.autoBoot == case.autoBoot;
    assert boot.bootloader.outPath == expected.outPath;
    assert boot.bootloader.bootloaderFeatures == case.features;
    case.name
  ) cases;

  diskDefault = evaluate bootloaderVariants { };
  liveDefault = evaluate bootloaderVariants { liveMode = true; };
  overridden = evaluate bootloaderVariants {
    liveMode = true;
    autoBoot = true;
    bootloader = bootloaderVariants.bootloader;
  };
  missing = builtins.map (
    case:
    let
      packages = builtins.removeAttrs bootloaderVariants [ case.variant ];
      result = builtins.tryEval (
        (evaluate packages { inherit (case) liveMode autoBoot; }).bootloader.outPath
      );
    in
    assert !result.success;
    case.name
  ) cases;
in
{
  bootloader-feature-matrix =
    assert diskDefault.autoBoot == false;
    assert diskDefault.bootloader.outPath == bootloaderVariants.bootloader.outPath;
    assert liveDefault.autoBoot == true;
    assert liveDefault.bootloader.outPath == bootloaderVariants.bootloaderLiveAutoboot.outPath;
    assert overridden.bootloader.outPath == bootloaderVariants.bootloader.outPath;
    pkgs.runCommand "test-bootloader-feature-matrix"
      {
        matrixJSON = builtins.toJSON matrix;
        missingJSON = builtins.toJSON missing;
      }
      ''
        printf '%s\n' "$matrixJSON" "$missingJSON"
        touch $out
      '';

  bootloader-autoboot-patch =
    pkgs.runCommand "test-bootloader-autoboot-patch"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        # Keep the repository-relative test/patch layout without importing the
        # complete repository (or depending on a mutable local checkout).
        mkdir -p nix/tests nix/pkgs/system/patches/bootloader
        cp ${./test-bootloader-autoboot.py} nix/tests/test-bootloader-autoboot.py
        cp ${../pkgs/system/patches/bootloader/patch-bootloader-autoboot.py} \
          nix/pkgs/system/patches/bootloader/patch-bootloader-autoboot.py
        python3 nix/tests/test-bootloader-autoboot.py ${bootloader-src}
        touch $out
      '';
}
