# Serial-only, offline browser demonstration. Sizes intentionally retain module
# defaults until the native and browser runners have measured this exact image.
{ pkgs, lib }:
let
  fixtureDirectory = ../fixtures/browser-demo;
  fixtureNames = [
    "catalog.json" "run.sh" "session.sh" "ready.sh" "common.sh"
    "capture.sh"
    "build.nix" "builder.sh" "before.nix" "after.nix" "sample.txt"
  ];
  fixtureFiles = builtins.listToAttrs (map (name: {
    name = "etc/browser-demo/${name}";
    value = {
      text = builtins.readFile (fixtureDirectory + "/${name}");
      mode = if lib.hasSuffix ".sh" name then "0755" else "0644";
    };
  }) fixtureNames);
  evaluatorDirectory = ../../../snix-wasm/fixtures/v1;
  evaluatorNames = [
    "arithmetic.nix" "attributes.nix" "functions.nix" "bundled-import.nix"
    "source-data.nix" "manifest.json" "lib/math.nix"
  ];
  evaluatorFiles = builtins.listToAttrs (map (name: {
    name = "playground/v1/${name}";
    value = {
      text = builtins.readFile (evaluatorDirectory + "/${name}");
      mode = "0644";
    };
  }) evaluatorNames);
in
assert pkgs ? snix;
{
  "/boot" = {
    autoBoot = true;
    liveMode = false;
  };
  "/environment" = {
    # Snix is already a boot-essential seed package, not another guest build.
    # Required dependencies fail evaluation rather than silently shrinking the demo.
    systemPackages = [ pkgs.ion pkgs.uutils pkgs.redox-bash pkgs.browser-demo-flush ];
    binaryCachePackages = {
      ripgrep = pkgs.ripgrep;
      cache-closure-fixture = pkgs.cache-closure-fixture;
    };
    shellAliases = { };
    etc = fixtureFiles // evaluatorFiles // {
      "etc/redox-system/configuration.nix".text = builtins.readFile (fixtureDirectory + "/before.nix");
    };
  };
  "/time" = { hostname = "browser-demo"; timezone = "UTC"; ntpEnable = false; };
  "/networking" = { enable = false; remoteShellEnable = false; dns = [ ]; };
  "/graphics".enable = false;
  "/audio".enable = false;
  "/hardware" = {
    storageDrivers = [ "virtio-blkd" ];
    networkDrivers = [ ];
    graphicsEnable = false;
    graphicsDrivers = [ ];
    audioEnable = false;
    audioDrivers = [ ];
    usbEnable = false;
  };
  "/services".startupScriptText = ''
    /nix/system/profile/bin/bash /etc/browser-demo/session.sh
  '';
  "/virtualisation" = {
    memorySize = 1024;
    vmm = "qemu";
    cpus = 1;
    graphics = false;
    serialConsole = true;
    # The runner must also omit NIC/audio/USB devices, not only guest drivers.
    qemuExtraArgs = [ "-nic" "none" "-vga" "none" ];
  };
}
