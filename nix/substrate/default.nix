# Public Redox substrate surface for external OnixOS/Mantle consumers.
#
# This file is intentionally a pure functional core: it constructs a manifest,
# validates primitive plans, normalizes them, and translates them to the current
# internal Redox module/profile inputs. Callers decide whether to evaluate or
# build the resulting Redox system derivations.

{
  lib,
  pkgs,
  redoxSystemFactory,
  mkRedoxSystem,
  mkQemuRunners ? null,
  mkCloudHypervisorRunners ? null,
  packageIngredients ? { },
  target ? "x86_64-unknown-redox",
}:

let
  schemaVersion = "redox-substrate-v1";
  manifestApiPath = "legacyPackages.<system>.redoxSubstrate";

  serviceDefaultType = "nowait";
  serviceDefaultTarget = "rootfs";
  serviceDefaultPriority = 50;
  serviceDefaultEnable = true;

  fileDefaultMode = "0644";
  directoryRootPrefix = "/";
  relativeRootPrefix = "";

  minPrefixLength = 0;
  maxPrefixLength = 128;
  singleAddressPerInterfaceLimit = 1;

  supportedServiceTypes = [
    "oneshot"
    "daemon"
    "nowait"
    "scheme"
  ];
  supportedTargets = [
    "initfs"
    "rootfs"
  ];
  supportedNetworkModes = [
    "auto"
    "dhcp"
    "static"
    "none"
  ];
  primitiveFamilyNames = [
    "services"
    "users"
    "networking"
    "filesystem"
    "status"
    "image"
  ];
  builderEntrypoints = [
    "normalizePrimitivePlan"
    "primitivePlanToModule"
    "buildSystem"
    "evaluateArtifactPlan"
  ];
  runnerFamilies = [
    "qemu"
    "cloud-hypervisor"
  ];

  reservedGeneratedFilePaths = [
    "etc/hostname"
    "etc/passwd"
    "etc/group"
    "etc/shadow"
    "etc/profile"
    "etc/init.toml"
    "etc/redox-system/manifest.json"
    "startup.sh"
  ];

  privateImportMarkers = [
    "nix/flake-modules"
    "nix/pkgs/"
    "../pkgs/"
    "../../nix/pkgs"
  ];

  fail = field: message: throw "redox substrate ${field}: ${message}";

  ensure =
    field: message: condition: value:
    if condition then value else fail field message;
  ensureAttrs = field: value: ensure field "expected an attribute set" (builtins.isAttrs value) value;
  ensureString = field: value: ensure field "expected a string" (builtins.isString value) value;
  ensureNonEmptyString =
    field: value:
    let
      checked = ensureString field value;
    in
    ensure field "expected a non-empty string" (checked != "") checked;
  ensureBool = field: value: ensure field "expected a boolean" (builtins.isBool value) value;
  ensureInt = field: value: ensure field "expected an integer" (builtins.isInt value) value;
  ensureStringList =
    field: value:
    ensure field "expected a list of strings" (
      builtins.isList value && builtins.all builtins.isString value
    ) value;

  ensureNoUnknownKeys =
    field: allowedKeys: value:
    let
      checked = ensureAttrs field value;
      unknownKeys = builtins.filter (key: !(builtins.elem key allowedKeys)) (builtins.attrNames checked);
    in
    if unknownKeys == [ ] then
      checked
    else
      fail field "unsupported field(s): ${lib.concatStringsSep ", " unknownKeys}";

  ensureOneOf =
    field: allowedValues: value:
    let
      checked = ensureString field value;
    in
    ensure field "expected one of: ${lib.concatStringsSep ", " allowedValues}"
      (builtins.elem checked allowedValues)
      checked;

  ensureStringValues =
    field: value:
    let
      checked = ensureAttrs field value;
      badKeys = builtins.filter (key: !(builtins.isString checked.${key})) (builtins.attrNames checked);
    in
    if badKeys == [ ] then
      checked
    else
      fail field "expected string values for: ${lib.concatStringsSep ", " badKeys}";

  normalizeAbsolutePath =
    field: value:
    let
      checked = ensureNonEmptyString field value;
      segments = lib.splitString "/" checked;
    in
    if !(lib.hasPrefix directoryRootPrefix checked) then
      fail field "expected an absolute path"
    else if builtins.elem ".." segments then
      fail field "must not contain parent-directory traversal"
    else
      checked;

  normalizeRelativePath =
    field: value:
    let
      checked = ensureNonEmptyString field value;
      withoutRoot = lib.removePrefix directoryRootPrefix checked;
      segments = lib.splitString "/" withoutRoot;
    in
    if withoutRoot == relativeRootPrefix then
      fail field "must not target the filesystem root"
    else if builtins.elem ".." segments then
      fail field "must not contain parent-directory traversal"
    else
      withoutRoot;

  normalizeFileMode = field: value: ensureString field value;

  normalizeService =
    name: rawService:
    let
      field = "services.${name}";
      service = ensureNoUnknownKeys field [
        "description"
        "command"
        "argv"
        "args"
        "type"
        "wantedBy"
        "enable"
        "after"
        "environment"
        "priority"
      ] rawService;
      serviceType = ensureOneOf "${field}.type" supportedServiceTypes (
        service.type or serviceDefaultType
      );
      argv = if service ? argv then ensureStringList "${field}.argv" service.argv else [ ];
      args =
        if service ? args then
          ensureString "${field}.args" service.args
        else if serviceType == "scheme" && argv != [ ] then
          builtins.head argv
        else
          "";
      environment =
        if service ? environment then
          ensureStringValues "${field}.environment" service.environment
        else
          { };
    in
    {
      description = ensureString "${field}.description" (service.description or name);
      command = ensureNonEmptyString "${field}.command" service.command;
      type = serviceType;
      inherit args argv;
      wantedBy = ensureOneOf "${field}.wantedBy" supportedTargets (
        service.wantedBy or serviceDefaultTarget
      );
      enable =
        if service ? enable then ensureBool "${field}.enable" service.enable else serviceDefaultEnable;
      after = if service ? after then ensureStringList "${field}.after" service.after else [ ];
      inherit environment;
      priority =
        if service ? priority then
          ensureInt "${field}.priority" service.priority
        else
          serviceDefaultPriority;
    };

  normalizeAddress =
    field: rawAddress:
    if builtins.isString rawAddress then
      { address = normalizeNonEmptyAddress "${field}.address" rawAddress; }
    else
      let
        address = ensureNoUnknownKeys field [
          "address"
          "prefixLength"
          "gateway"
        ] rawAddress;
        prefixLength = address.prefixLength or null;
      in
      {
        address = normalizeNonEmptyAddress "${field}.address" address.address;
      }
      // lib.optionalAttrs (prefixLength != null) {
        prefixLength = ensurePrefixLength "${field}.prefixLength" prefixLength;
      }
      // lib.optionalAttrs (address ? gateway) {
        gateway = ensureNonEmptyString "${field}.gateway" address.gateway;
      };

  normalizeNonEmptyAddress = field: value: ensureNonEmptyString field value;

  ensurePrefixLength =
    field: value:
    let
      checked = ensureInt field value;
    in
    ensure field
      "expected an integer between ${toString minPrefixLength} and ${toString maxPrefixLength}"
      (checked >= minPrefixLength && checked <= maxPrefixLength)
      checked;

  normalizeInterface =
    name: rawInterface:
    let
      field = "networking.interfaces.${name}";
      iface = ensureNoUnknownKeys field [
        "address"
        "addresses"
        "prefixLength"
        "gateway"
        "netmask"
      ] rawInterface;
      addresses =
        if iface ? addresses then
          let
            checkedAddresses =
              ensure field "addresses must be a list" (builtins.isList iface.addresses)
                iface.addresses;
          in
          builtins.map (normalizeAddress "${field}.addresses") checkedAddresses
        else if iface ? address then
          [
            (normalizeAddress field (
              {
                inherit (iface) address;
              }
              // lib.optionalAttrs (iface ? prefixLength) { inherit (iface) prefixLength; }
              // lib.optionalAttrs (iface ? gateway) { inherit (iface) gateway; }
            ))
          ]
        else
          [ ];
    in
    {
      inherit addresses;
    }
    // lib.optionalAttrs (iface ? netmask) {
      netmask = ensureNonEmptyString "${field}.netmask" iface.netmask;
    };

  normalizeNetworking =
    rawNetworking:
    let
      networking = ensureNoUnknownKeys "networking" [
        "enable"
        "mode"
        "dns"
        "searchDomains"
        "hostname"
        "defaultRouter"
        "interfaces"
      ] rawNetworking;
      interfaces =
        if networking ? interfaces then builtins.mapAttrs normalizeInterface networking.interfaces else { };
    in
    {
      enable = if networking ? enable then ensureBool "networking.enable" networking.enable else true;
      mode = ensureOneOf "networking.mode" supportedNetworkModes (networking.mode or "auto");
      dns = if networking ? dns then ensureStringList "networking.dns" networking.dns else [ ];
      searchDomains =
        if networking ? searchDomains then
          ensureStringList "networking.searchDomains" networking.searchDomains
        else
          [ ];
      inherit interfaces;
    }
    // lib.optionalAttrs (networking ? hostname) {
      hostname = ensureNonEmptyString "networking.hostname" networking.hostname;
    }
    // lib.optionalAttrs (networking ? defaultRouter) {
      defaultRouter = ensureNonEmptyString "networking.defaultRouter" networking.defaultRouter;
    };

  normalizeUsers =
    rawUsers:
    let
      users = ensureNoUnknownKeys "users" [
        "users"
        "groups"
      ] rawUsers;
    in
    {
      users = if users ? users then ensureAttrs "users.users" users.users else { };
      groups = if users ? groups then ensureAttrs "users.groups" users.groups else { };
    };

  normalizeFilesystemFile =
    field: rawFile:
    if builtins.isString rawFile then
      {
        text = rawFile;
        mode = fileDefaultMode;
      }
    else
      let
        file = ensureNoUnknownKeys field [
          "text"
          "mode"
        ] rawFile;
      in
      {
        text = ensureString "${field}.text" file.text;
        mode = normalizeFileMode "${field}.mode" (file.mode or fileDefaultMode);
      };

  normalizeFilesystemFiles =
    rawFiles:
    let
      checked = ensureAttrs "filesystem.files" rawFiles;
      entries = builtins.map (path: {
        name = normalizeRelativePath "filesystem.files.${path}" path;
        value = normalizeFilesystemFile "filesystem.files.${path}" checked.${path};
      }) (builtins.attrNames checked);
      normalizedNames = builtins.map (entry: entry.name) entries;
      uniqueNames = lib.unique normalizedNames;
      conflictingGenerated = builtins.filter (
        name: builtins.elem name reservedGeneratedFilePaths
      ) normalizedNames;
    in
    if builtins.length uniqueNames != builtins.length normalizedNames then
      fail "filesystem.files" "multiple entries normalize to the same path"
    else if conflictingGenerated != [ ] then
      fail "filesystem.files" "conflicts with generated file(s): ${lib.concatStringsSep ", " conflictingGenerated}"
    else
      builtins.listToAttrs entries;

  normalizeFilesystem =
    rawFilesystem:
    let
      filesystem = ensureNoUnknownKeys "filesystem" [
        "directories"
        "files"
        "devSymlinks"
        "symlinks"
        "extraPaths"
      ] rawFilesystem;
    in
    {
      directories =
        if filesystem ? directories then
          builtins.map (normalizeAbsolutePath "filesystem.directories") (
            ensure "filesystem.directories" "expected a list" (builtins.isList filesystem.directories)
              filesystem.directories
          )
        else
          [ ];
      files = if filesystem ? files then normalizeFilesystemFiles filesystem.files else { };
      devSymlinks =
        if filesystem ? devSymlinks then
          ensureStringValues "filesystem.devSymlinks" filesystem.devSymlinks
        else
          { };
      symlinks =
        if filesystem ? symlinks then ensureStringValues "filesystem.symlinks" filesystem.symlinks else { };
      extraPaths =
        if filesystem ? extraPaths then
          ensure "filesystem.extraPaths" "expected a list" (builtins.isList filesystem.extraPaths)
            filesystem.extraPaths
        else
          [ ];
    };

  normalizeStatus =
    rawStatus:
    let
      status = ensureNoUnknownKeys "status" [ "hooks" ] rawStatus;
    in
    {
      hooks = if status ? hooks then status.hooks else [ ];
    };

  normalizeImage =
    rawImage:
    let
      image = ensureNoUnknownKeys "image" [
        "diskImage"
        "initfs"
        "vmRunner"
      ] rawImage;
    in
    {
      diskImage = if image ? diskImage then ensureBool "image.diskImage" image.diskImage else true;
      initfs = if image ? initfs then ensureBool "image.initfs" image.initfs else true;
    }
    // lib.optionalAttrs (image ? vmRunner) {
      vmRunner = ensureOneOf "image.vmRunner" runnerFamilies image.vmRunner;
    };

  normalizePrimitivePlan =
    rawPlan:
    let
      plan = ensureNoUnknownKeys "plan" primitiveFamilyNames rawPlan;
    in
    {
      services =
        if plan ? services then
          builtins.mapAttrs normalizeService (ensureAttrs "services" plan.services)
        else
          { };
      users =
        if plan ? users then
          normalizeUsers plan.users
        else
          {
            users = { };
            groups = { };
          };
      networking = if plan ? networking then normalizeNetworking plan.networking else { };
      filesystem =
        if plan ? filesystem then
          normalizeFilesystem plan.filesystem
        else
          {
            directories = [ ];
            files = { };
            devSymlinks = { };
            symlinks = { };
            extraPaths = [ ];
          };
      status = if plan ? status then normalizeStatus plan.status else { hooks = [ ]; };
      image =
        if plan ? image then
          normalizeImage plan.image
        else
          {
            diskImage = true;
            initfs = true;
          };
    };

  ensureBuildableInterface =
    name: iface:
    if builtins.length iface.addresses <= singleAddressPerInterfaceLimit then
      iface
    else
      fail "networking.interfaces.${name}.addresses" "current Redox builder supports at most ${toString singleAddressPerInterfaceLimit} static address per interface";

  adiosInterfaceFromPrimitive =
    networking: name: rawIface:
    let
      iface = ensureBuildableInterface name rawIface;
    in
    if iface.addresses == [ ] then
      { }
    else
      let
        primary = builtins.head iface.addresses;
      in
      {
        address = primary.address;
        gateway = primary.gateway or (networking.defaultRouter or "");
      }
      // lib.optionalAttrs (primary ? prefixLength) { inherit (primary) prefixLength; }
      // lib.optionalAttrs (iface ? netmask) { inherit (iface) netmask; };

  moduleFromNormalized =
    normalized:
    let
      networking = normalized.networking;
      filesystem = normalized.filesystem;
      networkingModule =
        if networking == { } then
          { }
        else
          {
            "/networking" = {
              inherit (networking) enable mode;
            }
            // lib.optionalAttrs (networking.dns != [ ]) { inherit (networking) dns; }
            // lib.optionalAttrs (networking.searchDomains != [ ]) { inherit (networking) searchDomains; }
            // lib.optionalAttrs (networking ? defaultRouter) { inherit (networking) defaultRouter; }
            // lib.optionalAttrs (networking.interfaces != { }) {
              interfaces = builtins.mapAttrs (adiosInterfaceFromPrimitive networking) networking.interfaces;
            };
          }
          // lib.optionalAttrs (networking ? hostname) {
            "/time" = { inherit (networking) hostname; };
          };
    in
    networkingModule
    // lib.optionalAttrs (normalized.services != { }) {
      "/services" = {
        services = normalized.services;
      };
    }
    // lib.optionalAttrs (normalized.users.users != { } || normalized.users.groups != { }) {
      "/users" =
        lib.optionalAttrs (normalized.users.users != { }) { inherit (normalized.users) users; }
        // lib.optionalAttrs (normalized.users.groups != { }) { inherit (normalized.users) groups; };
    }
    //
      lib.optionalAttrs
        (
          filesystem.directories != [ ]
          || filesystem.files != { }
          || filesystem.devSymlinks != { }
          || filesystem.symlinks != { }
          || filesystem.extraPaths != [ ]
        )
        {
          "/filesystem" =
            lib.optionalAttrs (filesystem.directories != [ ]) { substrateDirectories = filesystem.directories; }
            // lib.optionalAttrs (filesystem.files != { }) { extraFiles = filesystem.files; }
            // lib.optionalAttrs (filesystem.devSymlinks != { }) { extraDevSymlinks = filesystem.devSymlinks; }
            // lib.optionalAttrs (filesystem.symlinks != { }) { extraSpecialSymlinks = filesystem.symlinks; }
            // lib.optionalAttrs (filesystem.extraPaths != [ ]) { inherit (filesystem) extraPaths; };
        };

  primitivePlanToModule = rawPlan: moduleFromNormalized (normalizePrimitivePlan rawPlan);

  evaluateArtifactPlan =
    { plan }:
    let
      normalized = normalizePrimitivePlan plan;
      module = moduleFromNormalized normalized;
    in
    {
      inherit normalized module;
      artifacts = {
        rootTree = true;
        initfs = normalized.image.initfs;
        diskImage = normalized.image.diskImage;
        vmRunner = normalized.image.vmRunner or null;
      };
      provenance = {
        schema = schemaVersion;
        compatibilityBoundary = "redox-adios-internal";
      };
    };

  buildSystem =
    {
      plan,
      modules ? [ ],
    }:
    let
      artifactPlan = evaluateArtifactPlan { inherit plan; };
      system = mkRedoxSystem { modules = modules ++ [ artifactPlan.module ]; };
    in
    system
    // {
      substrate = {
        inherit artifactPlan;
        manifest = manifest;
        normalizedPlan = artifactPlan.normalized;
      };
    };

  consumerSourceHasPrivateImport =
    source: builtins.any (marker: lib.hasInfix marker source) privateImportMarkers;

  validateConsumerSource =
    source:
    if consumerSourceHasPrivateImport source then
      fail "consumer.imports" "fixture imports private Redox internals"
    else
      true;

  requireIngredient =
    section: name:
    let
      ingredientsBySection = {
        builders = builderEntrypoints;
        primitiveFamilies = primitiveFamilyNames;
        runners = runnerFamilies;
        packages = builtins.concatLists (builtins.attrValues (manifest.packages or { }));
      };
      available =
        ingredientsBySection.${section} or (fail "manifest.${section}" "unknown ingredient section");
    in
    if builtins.elem name available then
      name
    else
      fail "manifest.${section}.${name}" "missing ingredient '${name}'";

  manifest = {
    schema = schemaVersion;
    api = manifestApiPath;
    redox = {
      inherit target;
      systemBuilderVersion = redoxSystemFactory.version or "unknown";
    };
    packages = {
      runtime =
        packageIngredients.runtime or [
          "relibc"
          "kernel"
          "bootloader"
          "base"
          "redoxfs"
        ];
      userspace =
        packageIngredients.userspace or [
          "ion"
          "uutils"
          "netutils"
          "extrautils"
          "openssh"
          "snix"
        ];
      infrastructure =
        packageIngredients.infrastructure or [
          "initfsTools"
          "bootstrap"
          "qemu-runner"
          "cloud-hypervisor-runner"
        ];
    };
    builders = {
      rootTree = true;
      initfs = true;
      diskImage = true;
      vmRunner = mkQemuRunners != null || mkCloudHypervisorRunners != null;
      compatibilityShell = true;
      entrypoints = builderEntrypoints;
    };
    primitives = {
      services = {
        structuredArgv = true;
        legacyArgs = true;
        supportedTypes = supportedServiceTypes;
        supportedTargets = supportedTargets;
      };
      users = {
        supported = true;
      };
      networking = {
        supported = true;
        modes = supportedNetworkModes;
        dnsSearchDomains = true;
        ipv6Literals = true;
        staticAddressPrefixLength = true;
      };
      filesystem = {
        directories = true;
        generatedFiles = true;
        symlinks = true;
      };
      status = {
        hooks = "validation-only";
      };
      image = {
        diskImage = true;
        initfs = true;
        vmRunner = true;
      };
    };
    runnerCapabilities = {
      qemu = {
        available = mkQemuRunners != null;
        modes = [
          "headless"
          "graphical"
        ];
      };
      cloud-hypervisor = {
        available = mkCloudHypervisorRunners != null;
        modes = [
          "headless"
          "network"
          "shared-fs"
        ];
      };
    };
    provenance = {
      project = "redox-nix";
      boundary = "substrate-only";
      redoxAdios = "internal-native-development-compatibility";
      externalSystemSemantics = "owned-by-onixos-or-other-frontends";
      nixBootstrapEvidence = "distinct-from-mantle-no-nix-runtime-evidence";
    };
  };

in
{
  inherit manifest;

  manifestTools = {
    inherit requireIngredient;
  };

  primitives = {
    normalizePlan = normalizePrimitivePlan;
    validatePlan = plan: builtins.deepSeq (normalizePrimitivePlan plan) true;
    toModule = primitivePlanToModule;
    service = normalizeService;
    networking = normalizeNetworking;
    filesystem = normalizeFilesystem;
  };

  builders = {
    inherit
      evaluateArtifactPlan
      primitivePlanToModule
      buildSystem
      ;
  };

  testing = {
    inherit
      consumerSourceHasPrivateImport
      validateConsumerSource
      ;
  };
}
