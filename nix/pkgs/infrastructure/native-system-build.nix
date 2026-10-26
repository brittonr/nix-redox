# Native system graph. This file is staged at /usr/src/nix-redox/build.nix.
{ config, currentManifest }:
let
  lib = import ./lib;
  seed = builtins.fromJSON (builtins.readFile ./seed.json);
  present = attrs: name: fallback:
    if attrs ? ${name} && attrs.${name} != null then attrs.${name} else fallback;
  section = name: present config name { };
  oldConfiguration = currentManifest.configuration or { };
  oldHardware = oldConfiguration.hardware or seed.inputs.hardware;
  hardware = lib.genAttrs [
    "storageDrivers" "networkDrivers" "graphicsDrivers" "audioDrivers" "usbEnabled"
  ] (name: present (section "hardware") name
    (present oldHardware name (seed.inputs.hardware.${name} or seed.cfg.usbEnabled)));
  graphicsEnabled = present (section "graphics") "enable"
    (currentManifest.configuration.graphics.enabled or seed.cfg.graphicsEnabled);
  networkingEnabled = present (section "networking") "enable"
    (currentManifest.configuration.networking.enabled or true);
  usbEnabled = hardware.usbEnabled || graphicsEnabled;
  initfsEnableGraphics = graphicsEnabled || (seed.cfg.initfsForceGraphics or
    (seed.cfg.initfsEnableGraphics && !seed.cfg.graphicsEnabled));
  allDrivers = lib.unique (
    hardware.storageDrivers ++ hardware.networkDrivers
    ++ lib.optionals graphicsEnabled hardware.graphicsDrivers
    ++ lib.optionals seed.cfg.audioEnabled hardware.audioDrivers
    ++ lib.optional usbEnabled "xhcid"
    ++ (seed.cfg.initfsExtraDrivers or [ ])
  );
  coreDaemons = builtins.filter (n: n != "smolnetd" && n != "ps2d") seed.cfg.coreDaemons
    ++ lib.optional networkingEnabled "smolnetd"
    ++ lib.optional initfsEnableGraphics "ps2d";
  initfsDaemons = lib.optionals initfsEnableGraphics [ "vesad" "inputd" "fbbootlogd" "fbcond" ]
    ++ lib.optionals usbEnabled [ "xhcid" "usbhubd" "usbhidd" "inputd" ];
  extraDaemons = builtins.filter (n:
    !(builtins.elem n (seed.cfg.coreDaemons ++ seed.cfg.initfsDaemons))
  ) seed.cfg.allDaemons;
  cfg = seed.cfg // {
    inherit usbEnabled initfsEnableGraphics graphicsEnabled allDrivers coreDaemons initfsDaemons;
    allDaemons = lib.unique (builtins.filter (name:
      !(builtins.elem name (seed.cfg.initfsExcludeDaemons or [ ]))
    ) (coreDaemons ++ initfsDaemons ++ extraDaemons));
  };

  # The manifest contributes declarations added by the booted profile; seed
  # declarations retain details (argv, explicit priority) absent from metadata.
  seedServices = seed.inputs.services._generatedServices
    // (seed.inputs.networking.services or { })
    // (seed.inputs.graphics.services or { })
    // (seed.inputs.audio.services or { })
    // (seed.inputs.snix.services or { })
    // (seed.inputs.iroh.services or { })
    // seed.inputs.services.services;
  availableServices = lib.mapAttrs (name: svc: {
    enable = true;
    description = name;
    command = name;
    type = "daemon";
    args = "";
    wantedBy = "rootfs";
    environment = { };
    after = [ ];
  } // (seedServices.${name} or { }) // svc) (
    seedServices // (currentManifest.services.declared or { })
  );
  selectedNames = present config "services"
    (builtins.attrNames (currentManifest.services.declared or availableServices));
  unknownServices = builtins.filter (n: !(availableServices ? ${n})) selectedNames;
  selectedServices = builtins.listToAttrs (map (name: {
    inherit name;
    value = availableServices.${name} // { enable = true; };
  }) selectedNames);
  inputs = seed.inputs // {
    services = seed.inputs.services // {
      _generatedServices = { };
      services = selectedServices;
    };
    networking = { services = { }; };
    graphics = { services = { }; };
    audio = { services = { }; };
    snix = { services = { }; };
    iroh = { services = { }; };
  };
  initScripts = import ./renderers/init-scripts.nix { inherit lib cfg inputs; pkgs = { }; };
  pcid = import ./renderers/pcid.nix {
    inherit lib allDrivers;
    extraPciDrivers = seed.inputs.hardware.extraPciDrivers or { };
  };

  # Path values are imported into the store by derivationStrict: edits to the
  # staged source, recipes or vendor trees change the native derivation IDs.
  bootstrapInputs = builtins.toJSON { inherit (seed) bootstrapInputs packages; };
  mkNative = name: attrs: script: derivation ({
    inherit name bootstrapInputs;
    system = "x86_64-unknown-redox";
    builder = "/nix/system/profile/bin/bash";
    args = [ "--noprofile" "--norc" "-c" (''
      set -eu
      export PATH=/nix/system/profile/bin:/bin:/usr/bin
      export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
    '' + script) ];
  } // attrs);
  kernel = import /usr/src/native-kernel-rebuild/kernel/build.nix;
  bootloader = import /usr/src/native-kernel-rebuild/bootloader/build.nix;
  tools = import ./tools.nix;
  pkgs = {
    base = ./packages/base;
    bootstrap = ./packages/bootstrap;
    ion = ./packages/ion;
    redoxfsTarget = ./packages/redoxfs;
    initfsTools = tools;
  } // lib.optionalAttrs (builtins.pathExists ./packages/netutils) { netutils = ./packages/netutils; }
    // lib.optionalAttrs (builtins.pathExists ./packages/userutils) { userutils = ./packages/userutils; };
  initfs = import ./renderers/initfs.nix {
    inherit pkgs lib cfg;
    inherit (initScripts) initScriptFiles;
    inherit (pcid) pcidToml;
    hostPkgs.stdenv.mkDerivation = attrs: mkNative "redox-initfs-native" { } (''
      export PATH=${tools}/bin:$PATH
      cd "$TMPDIR"
      runHook() { :; }
      # Missing requested drivers must fail, not produce an unbootable archive.
      ${lib.concatMapStringsSep "\n" (driver: ''
        if [ ! -f ${pkgs.base}/bin/${lib.escapeShellArg driver} ]; then
          echo ${lib.escapeShellArg "Native initfs: unavailable driver ${driver}"} >&2
          exit 1
        fi
      '') allDrivers}
    '' + attrs.buildPhase + attrs.installPhase);
  };

  # Source package recipes are ordinary native derivations. Preserve bootstrap
  # packages by name even when selecting a smaller managed package set.
  packageSources = present config "packageSources" null;
  sourcePackages = if packageSources == null then { } else import packageSources;
  sourceRecords = lib.mapAttrsToList (name: drv: {
    inherit name;
    version = drv.version or "native";
    storePath = toString drv;
  }) sourcePackages;
  toPackageSet = packages: builtins.listToAttrs (map (p: { name = p.name; value = p; }) packages);
  seedPackageSet = toPackageSet seed.packages;
  availablePackages = seedPackageSet // toPackageSet (currentManifest.packages or [ ])
    // toPackageSet sourceRecords;
  requestedPackages = present config "packages" [ ];
  unknownPackages = builtins.filter (name: !(availablePackages ? ${name})) requestedPackages;
  selectedPackages = if requestedPackages == [ ] then availablePackages else
    seedPackageSet // builtins.listToAttrs (map (name: {
      inherit name;
      value = availablePackages.${name};
    }) requestedPackages) // toPackageSet sourceRecords;
  packages = builtins.attrValues selectedPackages;
  hostname = present config "hostname" currentManifest.system.hostname;
  timezone = present config "timezone" currentManifest.system.timezone;
  security = lib.genAttrs [ "protectKernelSchemes" "requirePasswords" "allowRemoteRoot" ]
    (name: present (section "security") name (oldConfiguration.security.${name} or false));
  boot = {
    kernel = "${kernel}/boot/kernel";
    initfs = "${initfs}/boot/initfs";
    bootloader = "${bootloader}/boot/EFI/BOOT/BOOTX64.EFI";
  };
  manifest = currentManifest // {
    manifestVersion = 3;
    system = currentManifest.system // { inherit hostname timezone; };
    inherit boot packages;
    configuration = oldConfiguration // {
      hardware = hardware // { inherit usbEnabled; };
      inherit security;
    };
    drivers = { all = allDrivers; initfs = initfsDaemons; core = coreDaemons; };
    services = {
      declared = initScripts.declaredServicesForManifest;
      initScripts = builtins.attrNames initScripts.allInitScriptsWithServices;
      startupScript = "/startup.sh";
    };
    generation = (currentManifest.generation or { }) // {
      # This digest is metadata, not a dependency-bearing string. The boot and
      # package fields above retain the graph's original store-path contexts.
      buildHash = builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (builtins.toJSON {
        inherit config boot packages bootstrapInputs;
        services = initScripts.declaredServicesForManifest;
      }));
      description = "native system rebuild";
    };
    # The parent hashes/materializes the newly rendered files before activation.
    files = currentManifest.files or { };
  };
  writeFile = path: text: ''
    mkdir -p "$out/"${lib.escapeShellArg (builtins.dirOf path)}
    printf '%s' ${lib.escapeShellArg text} > "$out/"${lib.escapeShellArg path}
  '';
  renderedScripts = lib.mapAttrsToList (name: script: {
    path = "${if (script.directory or "init.d") == "init.d" then "etc/init.d" else script.directory}/${name}";
    inherit (script) text;
  }) initScripts.allInitScriptsWithServices;
  etc = mkNative "redox-etc-native" { source = ./seed-etc; } (''
    mkdir -p "$out"
    cp -r "$source/." "$out/"
    chmod -R u+w "$out"
    rm -rf "$out/etc/init.d" "$out/usr/lib/init.d"
    mkdir -p "$out/etc/init.d" "$out/etc/pcid.d" "$out/etc/security"
  '' + writeFile "etc/hostname" hostname
    + writeFile "etc/timezone" timezone
    + writeFile "etc/hosts" "127.0.0.1 localhost ${hostname}\n::1 localhost ${hostname}\n"
    + writeFile "etc/pcid.d/initfs.toml" pcid.pcidToml
    + writeFile "etc/security/policy" (lib.concatStringsSep "\n" [
      "# Security policy (generated by native system build)"
      "protect_kernel_schemes=${lib.boolToString security.protectKernelSchemes}"
      "require_passwords=${lib.boolToString security.requirePasswords}"
      "allow_remote_root=${lib.boolToString security.allowRemoteRoot}"
    ])
    + writeFile "etc/redox-system/manifest.json" (builtins.toJSON manifest)
    + lib.concatMapStringsSep "\n" (script: writeFile script.path script.text)
      (builtins.filter (s: lib.hasPrefix "etc/" s.path) renderedScripts));
in
assert lib.assertMsg (unknownServices == [ ])
  "Unknown native service(s): ${lib.concatStringsSep ", " unknownServices}";
assert lib.assertMsg (unknownPackages == [ ])
  "Unknown native package(s): ${lib.concatStringsSep ", " unknownPackages}; provide packageSources";
mkNative "redox-system-native" {
  manifestJSON = builtins.toJSON (manifest // { etcSource = toString etc; });
  # Keep every source derivation in the graph, including packages with no bins.
  sourceOutputs = map toString (builtins.attrValues sourcePackages);
} (''
  mkdir -p "$out/boot/EFI/BOOT" "$out/root-files"
  cp ${kernel}/boot/kernel "$out/boot/kernel"
  cp ${initfs}/boot/initfs "$out/boot/initfs"
  cp ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI "$out/boot/EFI/BOOT/BOOTX64.EFI"
  printf '%s' "$manifestJSON" > "$out/manifest.json"
  printf '%s' "$out" > "$out/toplevel-path"
  printf '%s' ${lib.escapeShellArg (toString etc)} > "$out/etc-source-path"
  ln -s ${etc}/etc "$out/etc"
  ln -s ${tools} "$out/native-tools"
'' + writeFile "root-files/startup.sh" initScripts.startupContent
  + ''chmod 0755 "$out/root-files/startup.sh"
  ''
  + lib.concatMapStringsSep "\n" (script:
    writeFile "root-files/${script.path}" script.text
  ) (builtins.filter (s: !(lib.hasPrefix "etc/" s.path)) renderedScripts))
