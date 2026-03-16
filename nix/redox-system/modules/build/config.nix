# Configuration computations and package partitioning
# Extracts configuration values from module inputs and computes
# derived values like package lists, drivers, directories, etc.

{ lib, inputs, pkgs, redoxLib }:

let
  # ===== SHARED COMPUTATIONS =====

  graphicsEnabled = inputs.graphics.enable or false;
  networkingEnabled = inputs.networking.enable or false;
  usbEnabled = (inputs.hardware.usbEnable or false) || graphicsEnabled;
  audioEnabled = inputs.hardware.audioEnable or false;
  initfsEnableGraphics = (inputs.boot.initfsEnableGraphics or false) || graphicsEnabled;
  initfsSizeMB = inputs.boot.initfsSizeMB or 64;

  # ===== NEW MODULE OPTIONS =====

  # /time
  hostname = inputs.time.hostname or "redox";
  timezone = inputs.time.timezone or "UTC";
  ntpEnabled = inputs.time.ntpEnable or false;
  ntpServers = inputs.time.ntpServers or [ "pool.ntp.org" ];
  hwclock = inputs.time.hwclock or "utc";

  # /logging
  logLevel = inputs.logging.level or "info";
  kernelLogLevel = inputs.logging.kernelLogLevel or "warn";
  logToFile = inputs.logging.logToFile or true;
  logPath = inputs.logging.logPath or "/var/log";

  # /security
  protectKernelSchemes = inputs.security.protectKernelSchemes or true;
  requirePasswords = inputs.security.requirePasswords or false;
  allowRemoteRoot = inputs.security.allowRemoteRoot or false;
  setuidPrograms =
    inputs.security.setuidPrograms or [
      "su"
      "sudo"
      "login"
      "passwd"
    ];

  # /programs
  ionConfig =
    inputs.programs.ion or {
      enable = true;
      prompt = "\\$USER@\\$HOSTNAME \\$PWD# ";
      initExtra = "";
    };
  helixConfig =
    inputs.programs.helix or {
      enable = false;
      theme = "default";
    };
  defaultEditor = inputs.programs.editor or "/bin/sodium";
  httpdConfig =
    inputs.programs.httpd or {
      enable = false;
      port = 8080;
      rootDir = "/var/www";
    };

  # /power
  acpiEnabled = inputs.power.acpiEnable or true;
  powerAction = inputs.power.powerAction or "shutdown";
  rebootOnPanic = inputs.power.rebootOnPanic or false;

  # Compute all drivers
  allDrivers = lib.unique (
    (inputs.hardware.storageDrivers or [ ])
    ++ (inputs.hardware.networkDrivers or [ ])
    ++ (lib.optionals graphicsEnabled (inputs.hardware.graphicsDrivers or [ ]))
    ++ (lib.optionals audioEnabled (inputs.hardware.audioDrivers or [ ]))
    ++ (lib.optional usbEnabled "xhcid")
    ++ (inputs.boot.initfsExtraDrivers or [ ])
  );

  # Core daemons for initfs
  coreDaemons = [
    "init"
    "logd"
    "ramfs"
    "randd"
    "zerod"
    "pcid"
    "pcid-spawner"
    "lived"
    "acpid"
    "hwd"
    "rtcd"
    "ptyd"
    "ipcd"
  ]
  ++ lib.optional initfsEnableGraphics "ps2d"
  ++ lib.optional networkingEnabled "smolnetd";

  initfsDaemons =
    (lib.optionals initfsEnableGraphics [
      "vesad"
      "inputd"
      "fbbootlogd"
      "fbcond"
    ])
    ++ (lib.optionals usbEnabled [
      "xhcid"
      "usbhubd"
      "usbhidd"
    ]);

  allDaemons = lib.unique (coreDaemons ++ initfsDaemons ++ (inputs.boot.initfsExtraBinaries or [ ]));

  # ===== STORE-BASED PACKAGE MANAGEMENT =====
  # Inspired by NixOS's /run/current-system/sw model.
  # Packages live in /nix/store/<hash>-<name>/ and are symlinked into
  # /nix/system/profile/bin/ (the "system profile").  Generation switching
  # rebuilds these symlinks so binaries actually appear/disappear in PATH.

  # Get Nix store path basename for a package (e.g. "abc123-ripgrep-unstable")
  pkgStoreName = pkg: builtins.baseNameOf (toString pkg);

  # Compare two derivations by output path (store identity).
  # Two derivations with the same outPath are the same build artifact,
  # regardless of pname, name, or any other metadata.
  samePackage = a: b: toString a == toString b;

  # Boot-essential packages: flat-copied to /bin/ for init scripts and early boot.
  # These survive generation switches — they're always available.
  #
  # Packages the profile actually requested via systemPackages.
  profileSystemPackages = inputs.environment.systemPackages or [ ];

  # Check if a package is referenced in the profile's systemPackages list.
  inSystemPackages = pkg: builtins.any (p: toString p == toString pkg) profileSystemPackages;

  # Listed by DERIVATION REFERENCE (pkgs.foo), not by name string.
  # This makes the partition immune to pname/parseDrvName changes —
  # if pkgs.base changes metadata, it still goes to /bin/ because we
  # reference the derivation itself, not its name.
  #
  # userutils is only boot-essential when the profile includes it in
  # systemPackages. Test profiles exclude userutils so that startup.sh
  # runs the test runner directly instead of getty.
  bootPackages = lib.unique (
    (lib.optional (pkgs ? base) pkgs.base)
    ++ (lib.optional (pkgs ? ion) pkgs.ion)
    ++ (lib.optional (pkgs ? uutils) pkgs.uutils)
    ++ (lib.optional (pkgs ? userutils && inSystemPackages pkgs.userutils) pkgs.userutils)
    ++ (lib.optional (networkingEnabled && pkgs ? netutils) pkgs.netutils)
    ++ (lib.optional (networkingEnabled && pkgs ? netcfg-setup) pkgs.netcfg-setup)
    ++ (lib.optional (pkgs ? snix) pkgs.snix)
    ++ (lib.optionals graphicsEnabled (
      lib.optional (pkgs ? orbital) pkgs.orbital
      ++ lib.optional (pkgs ? orbdata) pkgs.orbdata
      ++ lib.optional (pkgs ? orbterm) pkgs.orbterm
      ++ lib.optional (pkgs ? orbutils) pkgs.orbutils
    ))
  );

  # Self-hosting packages: need full store copy (lib/, sysroot/, include/).
  # Same pattern — derivation references, not name strings.
  selfHostingPackages = lib.unique (
    lib.optional (pkgs ? redox-rustc) pkgs.redox-rustc
    ++ lib.optional (pkgs ? redox-llvm) pkgs.redox-llvm
    ++ lib.optional (pkgs ? redox-sysroot) pkgs.redox-sysroot
    ++ lib.optional (pkgs ? redox-cmake) pkgs.redox-cmake
    ++ lib.optional (pkgs ? redox-libcxx) pkgs.redox-libcxx
    ++ lib.optional (pkgs ? redox-libstdcxx-shim) pkgs.redox-libstdcxx-shim
  );

  isSelfHostingPkg = pkg: builtins.any (sh: samePackage sh pkg) selfHostingPackages;

  # Managed packages: everything in systemPackages that isn't boot-essential.
  # These appear/disappear when switching generations.
  isBootPkg = pkg: builtins.any (b: samePackage b pkg) bootPackages;
  managedPackages = builtins.filter (pkg: !isBootPkg pkg) (inputs.environment.systemPackages or [ ]);

  # All packages: union of boot + managed (used for store population and manifest).
  allPackages = lib.unique (bootPackages ++ managedPackages);

  # Check if userutils (getty, login) is installed on rootFS
  # When present, startup.sh runs a login loop for serial console
  # authentication. When absent, startup.sh runs ion directly.
  userutilsInstalled =
    let
      uu = pkgs.userutils or null;
    in
    uu != null && builtins.any (p: p == uu) allPackages;

  # Collect all directories
  homeDirectories = lib.filter (d: d != null) (
    lib.mapAttrsToList (name: user: if user.createHome or false then user.home else null) (
      inputs.users.users or { }
    )
  );

  allDirectories =
    (inputs.filesystem.extraDirectories or [ ])
    ++ homeDirectories
    ++ (lib.optional networkingEnabled "/var/log")
    ++ (lib.optional logToFile logPath)
    ++ [ "/etc/security" ]
    ++ [
      "/nix/store"
      "/nix/system/profile/bin"
      "/nix/system/generations"
      "/nix/var/snix/profiles/default/bin"
      "/nix/var/snix/pathinfo"
      "/nix/var/snix/gcroots"
    ]
    ++ (lib.optional acpiEnabled "/etc/acpi")
    ++ (lib.optional (helixConfig.enable or false) "/etc/helix")
    ++ (lib.optional (httpdConfig.enable or false) (httpdConfig.rootDir or "/var/www"));

  # User for serial console
  nonRootUsers = lib.filterAttrs (name: user: (user.uid or 0) > 0) (inputs.users.users or { });
  defaultUser =
    if nonRootUsers != { } then
      let
        name = builtins.head (builtins.attrNames nonRootUsers);
      in
      {
        inherit name;
        home = nonRootUsers.${name}.home or "/home/${name}";
      }
    else
      {
        name = "root";
        home = "/root";
      };

  # ===== SELF-HOSTING TOOLCHAIN =====
  # Detect whether the Rust toolchain and sysroot are present.
  # When present, create well-known paths and cargo configuration.
  # Uses pkgs.* references directly — no name string matching.
  sysrootPkg = pkgs.redox-sysroot or null;
  rustcPkg = pkgs.redox-rustc or null;
  libstdcxxShimPkg = pkgs.redox-libstdcxx-shim or null;
  hasSelfHosting = rustcPkg != null && sysrootPkg != null;

  # ===== BINARY CACHE =====
  # Generate a local Nix binary cache from binaryCachePackages.
  # Included in rootTree at /nix/cache/ when non-empty.
  binaryCachePackages = inputs.environment.binaryCachePackages or { };
  hasBinaryCache = binaryCachePackages != { };

  # Disk sizing from other modules
  diskSizeMB = inputs.boot.diskSizeMB or 512;
  espSizeMB = inputs.boot.espSizeMB or 200;

  # Network interface resolution (for static config)
  firstIfaceName =
    let
      names = builtins.attrNames (inputs.networking.interfaces or { });
    in
    if names != [ ] then builtins.head names else null;
  firstIface =
    if firstIfaceName != null then inputs.networking.interfaces.${firstIfaceName} else null;

in
{
  inherit
    graphicsEnabled
    networkingEnabled
    usbEnabled
    audioEnabled
    initfsEnableGraphics
    initfsSizeMB
    hostname
    timezone
    ntpEnabled
    ntpServers
    hwclock
    logLevel
    kernelLogLevel
    logToFile
    logPath
    protectKernelSchemes
    requirePasswords
    allowRemoteRoot
    setuidPrograms
    ionConfig
    helixConfig
    defaultEditor
    httpdConfig
    acpiEnabled
    powerAction
    rebootOnPanic
    allDrivers
    coreDaemons
    initfsDaemons
    allDaemons
    pkgStoreName
    samePackage
    bootPackages
    selfHostingPackages
    isSelfHostingPkg
    isBootPkg
    managedPackages
    allPackages
    userutilsInstalled
    allDirectories
    defaultUser
    sysrootPkg
    rustcPkg
    libstdcxxShimPkg
    hasSelfHosting
    binaryCachePackages
    hasBinaryCache
    diskSizeMB
    espSizeMB
    firstIfaceName
    firstIface
    ;
}