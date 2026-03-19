# Configuration computations and package partitioning
# Extracts configuration values from module inputs and computes
# derived values like package lists, drivers, directories, etc.

{ lib, inputs, pkgs, redoxLib }:

let
  # ===== SHARED COMPUTATIONS =====

  graphicsEnabled = inputs.graphics.enable;
  networkingEnabled = inputs.networking.enable;
  usbEnabled = inputs.hardware.usbEnable || graphicsEnabled;
  audioEnabled = inputs.hardware.audioEnable;
  initfsEnableGraphics = inputs.boot.initfsEnableGraphics || graphicsEnabled;
  initfsSizeMB = inputs.boot.initfsSizeMB;

  # ===== NEW MODULE OPTIONS =====

  # /time — adios validates types and applies defaults from the module
  hostname = inputs.time.hostname;
  timezone = inputs.time.timezone;
  ntpEnabled = inputs.time.ntpEnable;
  ntpServers = inputs.time.ntpServers;
  hwclock = inputs.time.hwclock;

  # /logging
  logLevel = inputs.logging.level;
  kernelLogLevel = inputs.logging.kernelLogLevel;
  logToFile = inputs.logging.logToFile;
  logPath = inputs.logging.logPath;

  # /boot
  initfsPrompt = inputs.boot.initfsPrompt;
  rustBacktrace = inputs.boot.rustBacktrace;
  bootExtraEssentialPackages = inputs.boot.essentialPackages;

  # /security
  # Scheme lists for per-user login namespaces.
  # Configurable via security.defaultRootSchemes and security.defaultUserSchemes.
  # Used by generated-files.nix to produce /etc/login_schemes.toml.
  fullSchemes = inputs.security.defaultRootSchemes;
  restrictedSchemes = inputs.security.defaultUserSchemes;

  protectKernelSchemes = inputs.security.protectKernelSchemes;
  requirePasswords = inputs.security.requirePasswords;
  allowRemoteRoot = inputs.security.allowRemoteRoot;
  setuidPrograms = inputs.security.setuidPrograms;

  # /programs — adios validates types and applies defaults from the module
  ionConfig = inputs.programs.ion;
  helixConfig = inputs.programs.helix;
  defaultEditor = inputs.programs.editor;
  httpdConfig = inputs.programs.httpd;
  cargoConfig = inputs.programs.cargo;

  # /graphics (forwarded for init-scripts / generated-files)
  virtualTerminal = inputs.graphics.virtualTerminal;
  graphicsDisplay = inputs.graphics.display;

  # /networking
  defaultNetmask = inputs.networking.defaultNetmask;
  extraHosts = inputs.networking.extraHosts;

  # /environment
  motd = inputs.environment.motd;
  extraShells = inputs.environment.shells;
  extraSelfHostingPackages = inputs.environment.selfHostingPackages;

  # /power
  acpiEnabled = inputs.power.acpiEnable;
  powerAction = inputs.power.powerAction;
  rebootOnPanic = inputs.power.rebootOnPanic;

  # Compute all drivers
  allDrivers = lib.unique (
    inputs.hardware.storageDrivers
    ++ inputs.hardware.networkDrivers
    ++ (lib.optionals graphicsEnabled inputs.hardware.graphicsDrivers)
    ++ (lib.optionals audioEnabled inputs.hardware.audioDrivers)
    ++ (lib.optional usbEnabled "xhcid")
    ++ inputs.boot.initfsExtraDrivers
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

  allDaemons = lib.unique (coreDaemons ++ initfsDaemons ++ inputs.boot.initfsExtraBinaries);

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
  profileSystemPackages = inputs.environment.systemPackages;

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
  # Boot-essential packages: flat-copied to /bin/, survive generation switches.
  # Extra packages from boot.essentialPackages are merged in.
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
    ++ bootExtraEssentialPackages
  );

  # Self-hosting packages: need full store copy (lib/, sysroot/, include/).
  # Same pattern — derivation references, not name strings.
  # Extra packages from environment.selfHostingPackages are merged in.
  selfHostingPackages = lib.unique (
    lib.optional (pkgs ? redox-rustc) pkgs.redox-rustc
    ++ lib.optional (pkgs ? redox-llvm) pkgs.redox-llvm
    ++ lib.optional (pkgs ? redox-sysroot) pkgs.redox-sysroot
    ++ lib.optional (pkgs ? redox-cmake) pkgs.redox-cmake
    ++ lib.optional (pkgs ? redox-libcxx) pkgs.redox-libcxx
    ++ lib.optional (pkgs ? redox-libstdcxx-shim) pkgs.redox-libstdcxx-shim
    ++ extraSelfHostingPackages
  );

  isSelfHostingPkg = pkg: builtins.any (sh: samePackage sh pkg) selfHostingPackages;

  # Managed packages: everything in systemPackages that isn't boot-essential.
  # These appear/disappear when switching generations.
  isBootPkg = pkg: builtins.any (b: samePackage b pkg) bootPackages;
  managedPackages = builtins.filter (pkg: !isBootPkg pkg) inputs.environment.systemPackages;

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

  # ===== TYPED SERVICE MODULES =====
  # Single source of truth for typed service options.
  # adios validates types and applies defaults from /services module —
  # no `or` fallbacks needed here.
  sshOpts = inputs.services.ssh;
  sshEnabled = sshOpts.enable;

  svcHttpdOpts = inputs.services.httpd;
  svcHttpdEnabled = svcHttpdOpts.enable;

  gettyOpts = inputs.services.getty;
  gettyEnabled =
    if gettyOpts.enable == "true" then true
    else if gettyOpts.enable == "false" then false
    else userutilsInstalled;  # "auto"

  exampledOpts = inputs.services.exampled;
  exampledEnabled = exampledOpts.enable;

  # Collect all directories
  homeDirectories = lib.filter (d: d != null) (
    lib.mapAttrsToList (name: user: if user.createHome or false then user.home else null)
      inputs.users.users
  );

  # Per-path ownership overrides for redoxfs-ar.
  # Each user's home directory should be owned by that user.
  # Paths are relative to the root tree (no leading slash).
  ownershipMap = lib.filter (e: e != null) (
    lib.mapAttrsToList (
      name: user:
      if user.createHome or false then
        {
          path = lib.removePrefix "/" user.home;
          uid = user.uid;
          gid = user.gid;
        }
      else
        null
    ) inputs.users.users
  );

  allDirectories =
    inputs.filesystem.extraDirectories
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
    ++ (lib.optional helixConfig.enable "/etc/helix")
    ++ (lib.optional httpdConfig.enable httpdConfig.rootDir)
    # Typed service module directories
    ++ (lib.optional sshEnabled "/etc/ssh")
    ++ (lib.optional svcHttpdEnabled "/etc/httpd")
    ++ (lib.optional svcHttpdEnabled svcHttpdOpts.rootDir)
    # Activation scripts directory
    ++ (lib.optional (inputs.activation.scripts != { }) "/etc/redox-system/activation.d")
    # Parent directories for user-declared etc files (environment.etc)
    ++ (lib.unique (
      lib.filter (d: d != "" && d != "." && d != "/") (
        builtins.map (key: "/" + builtins.dirOf key)
          (builtins.attrNames inputs.environment.etc)
      )
    ));

  # User for serial console
  nonRootUsers = lib.filterAttrs (name: user: (user.uid or 0) > 0) inputs.users.users;
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
  hasBash = (pkgs.redox-bash or null) != null && builtins.any (p: p == pkgs.redox-bash) allPackages;

  # ===== BINARY CACHE =====
  # Generate a local Nix binary cache from binaryCachePackages.
  # Included in rootTree at /nix/cache/ when non-empty.
  binaryCachePackages = inputs.environment.binaryCachePackages;
  hasBinaryCache = binaryCachePackages != { };

  # Disk sizing from other modules
  diskSizeMB = inputs.boot.diskSizeMB;
  espSizeMB = inputs.boot.espSizeMB;

  # Network interface resolution (for static config)
  firstIfaceName =
    let
      names = builtins.attrNames inputs.networking.interfaces;
    in
    if names != [ ] then builtins.head names else null;
  firstIface =
    if firstIfaceName != null then inputs.networking.interfaces.${firstIfaceName} else null;

  # User-declared etc files (for checks validation)
  userEtcFiles = inputs.environment.etc;

  # Activation script names (for checks validation)
  activationScriptNames = builtins.attrNames inputs.activation.scripts;

in
{
  inherit
    fullSchemes
    restrictedSchemes
    graphicsEnabled
    networkingEnabled
    usbEnabled
    audioEnabled
    initfsEnableGraphics
    initfsSizeMB
    initfsPrompt
    rustBacktrace
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
    cargoConfig
    virtualTerminal
    graphicsDisplay
    defaultNetmask
    extraHosts
    motd
    extraShells
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
    ownershipMap
    defaultUser
    sysrootPkg
    rustcPkg
    libstdcxxShimPkg
    hasSelfHosting
    hasBash
    binaryCachePackages
    hasBinaryCache
    diskSizeMB
    espSizeMB
    firstIfaceName
    firstIface
    userEtcFiles
    activationScriptNames
    sshOpts
    sshEnabled
    svcHttpdOpts
    svcHttpdEnabled
    gettyOpts
    gettyEnabled
    exampledOpts
    exampledEnabled
    ;
}