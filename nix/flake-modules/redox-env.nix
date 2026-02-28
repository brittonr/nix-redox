# Shared RedoxOS build environment
#
# Consolidates configuration, toolchain setup, source patching, and package
# building into a single function. Replaces the flake-parts _module.args
# chain (config.nix → toolchain.nix → sources.nix → packages.nix).
#
# Called by modules that need the cross-compilation environment.
# Memoized per-system by the caller's let binding.
#
# Usage:
#   { pkgs, system, lib, self, ... }:
#   let
#     inputs = self.inputs;
#     env = import ./redox-env.nix { inherit pkgs system lib inputs; };
#   in
#   { packages = { inherit (env.modularPkgs.host) cookbook; }; }

{
  pkgs,
  system,
  lib,
  inputs,
}:

let
  # === Configuration (was config.nix) ===
  config = {
    rustNightlyDate = "2025-10-03";
    targetArch = "x86_64";
    diskImageSize = 512;
    espSize = 200;
    qemuMemory = 2048;
    qemuCpus = 4;
    enableNetworking = true;
    enableGraphics = false;
  };

  redoxTarget = "${config.targetArch}-unknown-redox";

  # === Toolchain (was toolchain.nix) ===
  pkgsWithOverlay = import inputs.nixpkgs {
    inherit system;
    overlays = [ inputs.rust-overlay.overlays.default ];
  };

  rustToolchain = pkgsWithOverlay.rust-bin.nightly.${config.rustNightlyDate}.default.override {
    extensions = [
      "rust-src"
      "rustfmt"
      "clippy"
      "rust-analyzer"
    ];
    targets = [ redoxTarget ];
  };

  craneLib = (inputs.crane.mkLib pkgsWithOverlay).overrideToolchain rustToolchain;

  # === Sources (was sources.nix) ===
  patchedSources = {
    base = pkgs.applyPatches {
      name = "base-patched";
      src = inputs.base-src;
      patches = [
        ../patches/base/0001-cloud-hypervisor-support.patch
      ];
      postPatch = ''
        substituteInPlace drivers/usb/xhcid/drivers.toml \
          --replace-fail 'command = ["usbhubd"' 'command = ["/scheme/initfs/lib/drivers/usbhubd"' \
          --replace-fail 'command = ["usbhidd"' 'command = ["/scheme/initfs/lib/drivers/usbhidd"'
      '';
    };
  };

  # === Library & sysroot ===
  redoxLib = import ../lib {
    inherit pkgs lib rustToolchain redoxTarget;
  };

  sysrootVendor = redoxLib.sysroot.vendor;

  # === Source inputs for modular packages ===
  srcInputs = {
    inherit (inputs)
      relibc-src
      kernel-src
      redoxfs-src
      installer-src
      redox-src
      openlibm-src
      compiler-builtins-src
      dlmalloc-rs-src
      cc-rs-src
      redox-syscall-src
      redox-scheme-src
      object-src
      rmm-src
      redox-path-src
      fdt-src
      bootloader-src
      uefi-src
      liblibc-src
      orbclient-src
      rustix-redox-src
      drm-rs-src
      redox-log-src
      ion-src
      helix-src
      binutils-src
      extrautils-src
      sodium-src
      netutils-src
      uutils-src
      filetime-src
      libredox-src
      orbital-src
      orbdata-src
      orbterm-src
      orbutils-src
      orbfont-src
      orbimage-src
      userutils-src
      termion-src
      ripgrep-src
      fd-src
      bat-src
      hexyl-src
      zoxide-src
      dust-src
      ;
    # Use patched base source with Cloud Hypervisor support
    base-src = patchedSources.base;
  };

  # === Modular packages ===
  modularPkgs = import ../pkgs {
    inherit
      pkgs
      lib
      craneLib
      rustToolchain
      sysrootVendor
      redoxTarget
      ;
    inputs = srcInputs;
  };

in
{
  inherit
    config
    redoxTarget
    rustToolchain
    craneLib
    pkgsWithOverlay
    patchedSources
    redoxLib
    sysrootVendor
    srcInputs
    modularPkgs
    ;
}
