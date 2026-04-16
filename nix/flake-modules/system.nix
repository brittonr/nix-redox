# RedoxOS system configurations module (adios-flake)
#
# Integrates the RedoxOS module system (nix/redox-system/) with the flake.
# Produces disk images, runners, and test scripts for each profile.
#
# Access:
#   nix build .#redox-default     # Default system (development profile)
#   nix build .#redox-minimal     # Minimal system
#   nix build .#redox-graphical   # Graphical system
#   nix build .#redox-cloud       # Cloud Hypervisor optimized

{
  pkgs,
  system,
  lib,
  self,
  self',
  ...
}:
let
  inputs = self.inputs;
  sharedEnv = self'.legacyPackages.redoxEnv;

  inherit (sharedEnv)
    rustToolchain
    craneLib
    sysrootVendor
    redoxTarget
    redoxLib
    modularPkgs
    ;

  # Import the RedoxOS module system factory
  redoxSystemFactory = import ../redox-system { inherit lib; };

  # Build a flat package set from modular packages.
  # The per-crate kernel (kernelPerCrate) replaces the monolithic crane build —
  # same output layout ($out/boot/{kernel,kernel.sym}), but each of the 43
  # crates is a separate Nix derivation for incremental caching.
  mkFlatPkgs =
    {
      extraPkgs ? { },
    }:
    modularPkgs.host
    // modularPkgs.system
    // {
      kernel = self'.packages.kernelPerCrate;
      kernelSyscallDebug = self'.packages.kernelSyscallDebug;
      base = self'.packages.basePerCrate;
    }
    // modularPkgs.userspace
    // {
      ion = self'.packages.ion;
      userutils = self'.packages.userutils;
    }
    // modularPkgs.infrastructure
    // extraPkgs;

  # Helper to create a system configuration
  mkSystem =
    {
      modules,
      extraPkgs ? { },
    }:
    let
      flatPkgs = mkFlatPkgs { inherit extraPkgs; };
    in
    redoxSystemFactory.redoxSystem {
      inherit modules;
      pkgs = flatPkgs;
      hostPkgs = pkgs;
    };

  # Collect extra packages from the packages module via self'
  extraPkgs = lib.filterAttrs (_: v: v != null) {
    sodium = self'.packages.sodium or null;
    orbital = self'.packages.orbital or null;
    orbdata = self'.packages.orbdata or null;
    orbterm = self'.packages.orbterm or null;
    orbutils = self'.packages.orbutils or null;
    userutils = self'.packages.userutils or null;
    ripgrep = self'.packages.ripgrep or null;
    fd = self'.packages.fd or null;
    bat = self'.packages.bat or null;
    hexyl = self'.packages.hexyl or null;
    zoxide = self'.packages.zoxide or null;
    dust = self'.packages.dust or null;
    tokei = self'.packages.tokei or null;
    lsd = self'.packages.lsd or null;
    shellharden = self'.packages.shellharden or null;
    smith = self'.packages.smith or null;
    exampled = self'.packages.exampled or null;
    wasmtime-redox = self'.packages.wasmtime-redox or null;
    irohd = self'.packages.irohd or null;
    snix = self'.packages.snix or null;
    stored = self'.packages.stored or null;
    ca-certificates = self'.packages.ca-certificates or null;
    redox-curl = self'.packages.redox-curl or null;
    openssh = self'.packages.openssh or null;
    redox-openssl3 = self'.packages.redox-openssl3 or null;
    pkgutils = self'.packages.pkgutils or null;

    # Bare metal / ecosystem libraries
    gdb-protocol = self'.packages.gdb-protocol or null;
    redox-intelflash = self'.packages.redox-intelflash or null;
    redox-buffer-pool = self'.packages.redox-buffer-pool or null;
    gdbstub = self'.packages.gdbstub or null;

    # Self-hosting: build tools
    redox-bash = self'.packages.redox-bash or null;
    gnu-make = self'.packages.gnu-make or null;
    redox-git = self'.packages.redox-git or null;
    redox-diffutils = self'.packages.redox-diffutils or null;
    redox-sed = self'.packages.redox-sed or null;
    redox-patch = self'.packages.redox-patch or null;
    strace-redox = self'.packages.strace-redox or null;

    # Self-hosting: LLVM + Rust toolchain
    redox-llvm = self'.packages.redox-llvm or null;
    redox-cmake = self'.packages.redox-cmake or null;
    redox-rustc = self'.packages.redox-rustc or null;
    redox-libstdcxx-shim = self'.packages.redox-libstdcxx-shim or null;
    redox-sysroot = self'.packages.redox-sysroot or null;
    lld-wrapper = self'.packages.lld-wrapper or null;
    proc-dump = self'.packages.proc-dump or null;
    waitpid-stress = self'.packages.waitpid-stress or null;
  };

  # Pre-built system configurations using profiles
  systems = {
    default = mkSystem {
      modules = [ ../redox-system/profiles/development.nix ];
      inherit extraPkgs;
    };

    minimal = mkSystem {
      modules = [ ../redox-system/profiles/minimal.nix ];
      inherit extraPkgs;
    };

    graphical = mkSystem {
      modules = [ ../redox-system/profiles/graphical.nix ];
      inherit extraPkgs;
    };

    cloud-hypervisor = mkSystem {
      modules = [ ../redox-system/profiles/cloud-hypervisor.nix ];
      inherit extraPkgs;
    };

    self-hosting = mkSystem {
      modules = [ ../redox-system/profiles/self-hosting.nix ];
      inherit extraPkgs;
    };

    bare-metal-gmktec = mkSystem {
      modules = [ ../redox-system/profiles/bare-metal-gmktec.nix ];
      # Use FOD base build (has igcd) instead of basePerCrate (no igcd in plan yet)
      extraPkgs = extraPkgs // {
        base = modularPkgs.system.base;
      };
    };
  };

  # Runner factory functions from the infrastructure module
  mkCHRunners = modularPkgs.infrastructure.mkCloudHypervisorRunners;
  mkQemuRunners = modularPkgs.infrastructure.mkQemuRunners;
  mkBootTest = modularPkgs.infrastructure.mkBootTest;

  bootloader = modularPkgs.system.bootloader;

  # === Runners for each profile ===

  defaultRunners = mkCHRunners {
    diskImage = systems.default.diskImage;
    vmConfig = systems.default.vmConfig;
  };
  defaultQemuRunners = mkQemuRunners {
    diskImage = systems.default.diskImage;
    inherit bootloader;
    vmConfig = systems.default.vmConfig;
  };

  minimalRunners = mkCHRunners {
    diskImage = systems.minimal.diskImage;
    vmConfig = systems.minimal.vmConfig;
  };

  # Self-hosting profile runners
  selfHostingRunners = mkCHRunners {
    diskImage = systems.self-hosting.diskImage;
    vmConfig = systems.self-hosting.vmConfig;
  };
  selfHostingQemuRunners = mkQemuRunners {
    diskImage = systems.self-hosting.diskImage;
    inherit bootloader;
    vmConfig = systems.self-hosting.vmConfig;
  };

  # Shared FS profile: development + virtio-fsd driver
  sharedFsSystem = mkSystem {
    modules = [
      ../redox-system/profiles/development.nix
      (
        { pkgs, lib }:
        {
          "/hardware" = {
            storageDrivers = [
              "virtio-blkd"
              "virtio-fsd"
            ];
          };
        }
      )
    ];
    inherit extraPkgs;
  };
  sharedFsRunners = mkCHRunners {
    diskImage = sharedFsSystem.diskImage;
    vmConfig = sharedFsSystem.vmConfig;
  };

  cloudRunners = mkCHRunners {
    diskImage = systems.cloud-hypervisor.diskImage;
    diskImageNet = systems.cloud-hypervisor.diskImage;
    vmConfig = systems.cloud-hypervisor.vmConfig;
  };

  graphicalQemuRunners = mkQemuRunners {
    diskImage = systems.graphical.diskImage;
    inherit bootloader;
    vmConfig = systems.graphical.vmConfig;
  };
  graphicalCHRunners = mkCHRunners {
    diskImage = systems.graphical.diskImage;
    vmConfig = systems.graphical.vmConfig;
  };

  bootTest = mkBootTest {
    diskImage = systems.minimal.diskImage;
    inherit bootloader;
  };

  mkFunctionalTest = modularPkgs.infrastructure.mkFunctionalTest;
  functionalTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/functional-test.nix ];
    inherit extraPkgs;
  };
  functionalTest = mkFunctionalTest {
    diskImage = functionalTestSystem.diskImage;
    inherit bootloader;
  };

  functionalSmokeTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/functional-smoke-test.nix ];
    extraPkgs = { };
  };
  functionalSmokeTest = mkFunctionalTest {
    diskImage = functionalSmokeTestSystem.diskImage;
    inherit bootloader;
    defaultTimeout = 60;
    defaultMode = "ch";
    enableQemu = false;
  };

  mkNetworkTest = modularPkgs.infrastructure.mkNetworkTest;
  networkTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/network-test.nix ];
    inherit extraPkgs;
  };
  networkTest = mkNetworkTest {
    diskImage = networkTestSystem.diskImage;
    inherit bootloader;
  };

  mkSshTest = modularPkgs.infrastructure.mkSshTest;
  sshTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/ssh-test.nix ];
    inherit extraPkgs;
  };
  sshTest = mkSshTest {
    diskImage = sshTestSystem.diskImage;
    inherit bootloader;
    vmConfig = sshTestSystem.vmConfig;
  };

  # Network install test: boots with networking, serves cache via HTTP
  mkNetworkInstallTest = modularPkgs.infrastructure.mkNetworkInstallTest;
  networkInstallTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/network-install-test.nix ];
    inherit extraPkgs;
  };
  testBinaryCache = import ../pkgs/infrastructure/test-binary-cache.nix {
    inherit pkgs lib;
    ripgrep = self'.packages.ripgrep or null;
  };
  networkInstallTest = mkNetworkInstallTest {
    diskImage = networkInstallTestSystem.diskImage;
    inherit bootloader;
    testCache = testBinaryCache;
  };

  # Channel update test: boots with networking, tests channel add/update/upgrade
  mkChannelUpdateTest = modularPkgs.infrastructure.mkChannelUpdateTest;
  channelUpdateTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/channel-update-test.nix ];
    inherit extraPkgs;
  };
  channelUpdateCache = import ../pkgs/infrastructure/channel-update-cache.nix {
    inherit pkgs lib;
    rootTree = channelUpdateTestSystem.rootTree;
    inherit testBinaryCache;
  };
  channelUpdateTest = mkChannelUpdateTest {
    diskImage = channelUpdateTestSystem.diskImage;
    inherit bootloader;
    channelCache = channelUpdateCache;
  };

  # snix source bundle for self-compile test
  snixSourceBundle = import ../pkgs/infrastructure/snix-source-bundle.nix {
    inherit pkgs;
    snix-redox-src = ../../snix-redox;
  };

  # ripgrep source bundle for flake-build-ripgrep test
  ripgrepSourceBundle = import ../pkgs/infrastructure/ripgrep-source-bundle.nix {
    inherit pkgs;
    ripgrep-src = inputs.ripgrep-src;
  };

  # test flake bundle for `snix build .#hello` VM test
  testFlakeBundle = import ../pkgs/infrastructure/test-flake-bundle.nix {
    inherit pkgs rustToolchain;
  };

  # cc-dep and workspace test bundles for complex build VM tests
  ccDepTestBundle = import ../pkgs/infrastructure/cc-dep-test-bundle.nix {
    inherit pkgs;
  };
  workspaceTestBundle = import ../pkgs/infrastructure/workspace-test-bundle.nix {
    inherit pkgs;
  };

  nativeKernelRebuildBundle = import ../pkgs/infrastructure/native-kernel-rebuild-bundle.nix {
    inherit
      pkgs
      lib
      craneLib
      rustToolchain
      sysrootVendor
      redoxTarget
      ;
    inherit (redoxLib) vendor;
    inherit (inputs)
      kernel-src
      rmm-src
      redox-path-src
      fdt-src
      bootloader-src
      uefi-src
      ;
  };

  auditSnixSourceBundle = pkgs.writeShellScriptBin "audit-snix-source-bundle" ''
        set -euo pipefail
        bundle="''${1:-}"
        if [ -z "$bundle" ]; then
          bundle=${snixSourceBundle}
        fi
        echo "[audit-snix-source-bundle] bundle=$bundle"
        ${pkgs.python3}/bin/python3 - "$bundle" <<'PY'
    from pathlib import Path
    import sys
    import tomllib

    bundle = Path(sys.argv[1])
    manifest_path = bundle / "Cargo.toml"
    if not manifest_path.is_file():
        print(f"[audit-snix-source-bundle] missing manifest: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    missing: list[str] = []
    checked: list[str] = []


    def expect(rel: str, kind: str = "file") -> None:
        path = bundle / rel
        checked.append(rel)
        ok = path.is_dir() if kind == "dir" else path.is_file()
        if not ok:
            missing.append(rel)


    for rel in ("build.nix", "build-snix.sh", ".cargo/config.toml"):
        expect(rel)
    for rel in ("vendor", "vendor/source-registry-0", "vendor/source-git-0"):
        expect(rel, "dir")

    manifest = tomllib.loads(manifest_path.read_text())
    bins = manifest.get("bin", [])
    snix_bin = next((entry for entry in bins if entry.get("name") == "snix"), None)
    if snix_bin is None:
        print("[audit-snix-source-bundle] Cargo.toml has no [[bin]] named snix", file=sys.stderr)
        sys.exit(1)

    snix_bin_path = snix_bin.get("path")
    if snix_bin_path:
        expect(snix_bin_path)

    for rel in (
        "upstream/castore/protos/snix.castore.v1.bin",
        "upstream/store/protos/snix.store.v1.bin",
        "upstream/build/protos/snix.build.v1.bin",
    ):
        expect(rel)

    if missing:
        print("[audit-snix-source-bundle] missing paths:", file=sys.stderr)
        for rel in missing:
            print(f"  - {rel}", file=sys.stderr)
        sys.exit(1)

    print(f"[audit-snix-source-bundle] ok: checked {len(checked)} paths")
    print(f"  bin snix: {snix_bin_path}")
    for entry in bins:
        if entry.get("name") == "snix":
            continue
        rel = entry.get("path")
        if rel:
            status = "present" if (bundle / rel).exists() else "not bundled"
            print(f"  skipped bin {entry.get('name', '<unnamed>')}: {rel} ({status})")
    PY
  '';

  auditNativeKernelRebuildBundle = pkgs.writeShellScriptBin "audit-native-kernel-rebuild-bundle" ''
        set -euo pipefail
        bundle="''${1:-}"
        if [ -z "$bundle" ]; then
          bundle=${nativeKernelRebuildBundle}
        fi
        echo "[audit-native-kernel-rebuild-bundle] bundle=$bundle"
        ${pkgs.python3}/bin/python3 - "$bundle" <<'PY'
    from pathlib import Path
    import json
    import sys

    bundle = Path(sys.argv[1])
    manifest_path = bundle / "bundle-manifest.json"
    if not manifest_path.is_file():
        print(f"[audit-native-kernel-rebuild-bundle] missing manifest: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    manifest = json.loads(manifest_path.read_text())
    missing: list[str] = []
    checked: list[str] = []


    def expect(rel: str, kind: str = "file") -> None:
        path = bundle / rel
        checked.append(rel)
        ok = path.is_dir() if kind == "dir" else path.is_file()
        if not ok:
            missing.append(rel)


    expect("bundle-manifest.json")
    expect("run-native-kernel-rebuild-test.sh")
    expect("rust-src/library/core/src/lib.rs")
    for rel in (
        "kernel/Cargo.toml",
        "kernel/Cargo.lock",
        "kernel/build.nix",
        "kernel/build-redox-kernel.sh",
        "kernel/.cargo/config.toml",
        "kernel/targets/x86_64-unknown-kernel.json",
        "bootloader/Cargo.toml",
        "bootloader/Cargo.lock",
        "bootloader/build.nix",
        "bootloader/build-redox-bootloader.sh",
        "bootloader/.cargo/config.toml",
    ):
        expect(rel)
    for rel in ("kernel/vendor", "bootloader/vendor"):
        expect(rel, "dir")

    required_manifest_paths = {
        "kernel": ["build_file", "build_script", "guest_dir", "target", "vendor_dir"],
        "bootloader": ["build_file", "build_script", "guest_dir", "target", "vendor_dir"],
        "toolchain": ["rust_src_path", "guest_bins"],
    }
    for section, keys in required_manifest_paths.items():
        section_value = manifest.get(section)
        if not isinstance(section_value, dict):
            print(f"[audit-native-kernel-rebuild-bundle] missing manifest section: {section}", file=sys.stderr)
            sys.exit(1)
        for key in keys:
            if key not in section_value:
                print(f"[audit-native-kernel-rebuild-bundle] missing manifest key: {section}.{key}", file=sys.stderr)
                sys.exit(1)

    if missing:
        print("[audit-native-kernel-rebuild-bundle] missing paths:", file=sys.stderr)
        for rel in missing:
            print(f"  - {rel}", file=sys.stderr)
        sys.exit(1)

    print(f"[audit-native-kernel-rebuild-bundle] ok: checked {len(checked)} paths")
    print(f"  kernel target: {manifest['kernel']['target']}")
    print(f"  bootloader target: {manifest['bootloader']['target']}")
    print(f"  rust src: {manifest['toolchain']['rust_src_path']}")
    PY
  '';

  selfHostingProofCapture = "${pkgs.python3}/bin/python3 ${../../scripts/self-hosting-proof-capture.py}";

  wrapFunctionalTest =
    {
      base,
      label,
      auditBundle ? null,
      auditCommand ? null,
    }:
    pkgs.writeShellScriptBin "functional-test" ''
      set -uo pipefail

      REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || pwd)
      COMMAND_STR=$(printf "%q " "${base}/bin/functional-test" "$@")
      COMMAND_STR="''${COMMAND_STR% }"

      init_args=(
        init
        --capture-root /var/tmp/redox-self-hosting-captures
        --flow ${label}
        --repo-root "$REPO_ROOT"
        --command "$COMMAND_STR"
        --shell-output
      )
      if [ -n "''${REDOX_CAPTURE_DIR:-}" ]; then
        init_args+=(--run-dir "$REDOX_CAPTURE_DIR")
      fi
      ${lib.optionalString (auditBundle != null) ''init_args+=(--bundle "${auditBundle}")''}
      eval "$(${selfHostingProofCapture} "''${init_args[@]}")"

      status=125
      finalize_capture() {
        ${selfHostingProofCapture} finalize \
          --run-dir "$RUN_DIR" \
          --exit-code "$status" || true
      }
      trap finalize_capture EXIT

      : > "$RUN_DIR/runner.log"
      exec > >(${pkgs.coreutils}/bin/tee -a "$RUN_DIR/runner.log") 2>&1

      export REDOX_VM_MONITOR_DIR="$RUN_DIR"
      echo "[capture] run_dir=$RUN_DIR"
      echo "[capture] run_id=$RUN_ID"
      ${lib.optionalString (auditCommand != null) ''
        if ${auditCommand}; then
          :
        else
          status=$?
          exit $status
        fi
      ''}
      ${lib.optionalString (auditCommand == null && auditBundle != null) ''
        if ${auditSnixSourceBundle}/bin/audit-snix-source-bundle ${auditBundle}; then
          :
        else
          status=$?
          exit $status
        fi
      ''}

      ${base}/bin/functional-test "$@"
      status=$?
      exit $status
    '';

  # Self-hosting test: boots self-hosting image, tests cargo build
  selfHostingTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/self-hosting-test.nix ];
    extraPkgs = extraPkgs // {
      snix-source-bundle = snixSourceBundle;
      ripgrep-source-bundle = ripgrepSourceBundle;
      test-flake-bundle = testFlakeBundle;
      cc-dep-test-bundle = ccDepTestBundle;
      workspace-test-bundle = workspaceTestBundle;
    };
  };
  selfHostingTestRaw = mkFunctionalTest {
    diskImage = selfHostingTestSystem.diskImage;
    inherit bootloader;
    memoryMB = 8192;
    cpus = 4;
    # The focused snix-compile rerun now takes ~3090s on a cold guest build,
    # the full suite still has source-rebuild checks after it, and the
    # rebuild-cycle proof now runs at the end of self-hosting-test.
    defaultTimeout = 6000;
  };
  selfHostingTest = wrapFunctionalTest {
    base = selfHostingTestRaw;
    label = "self-hosting-test";
    auditBundle = snixSourceBundle;
  };

  # Focused snix self-compile test — skips the 70 earlier smoke tests
  snixCompileTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/snix-compile-test.nix ];
    extraPkgs = extraPkgs // {
      snix-source-bundle = snixSourceBundle;
    };
  };
  snixCompileTestRaw = mkFunctionalTest {
    diskImage = snixCompileTestSystem.diskImage;
    inherit bootloader;
    memoryMB = 8192;
    cpus = 4;
    defaultTimeout = 3600; # focused self-compile only; leave headroom for j1 builds
  };
  snixCompileTest = wrapFunctionalTest {
    base = snixCompileTestRaw;
    label = "snix-compile-test";
    auditBundle = snixSourceBundle;
  };

  # Focused snix sandbox build test — skips the 42 quick tests
  snixSandboxTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/snix-sandbox-test.nix ];
    extraPkgs = extraPkgs // {
      snix-source-bundle = snixSourceBundle;
      ripgrep-source-bundle = ripgrepSourceBundle;
      test-flake-bundle = testFlakeBundle;
      cc-dep-test-bundle = ccDepTestBundle;
      workspace-test-bundle = workspaceTestBundle;
    };
  };
  snixSandboxTestRaw = mkFunctionalTest {
    diskImage = snixSandboxTestSystem.diskImage;
    inherit bootloader;
    memoryMB = 8192;
    cpus = 4;
    defaultTimeout = 600; # 4 sandbox builds, ~2 min each
  };
  snixSandboxTest = wrapFunctionalTest {
    base = snixSandboxTestRaw;
    label = "snix-sandbox-test";
    auditBundle = snixSourceBundle;
  };

  # Focused native kernel rebuild test — builds the kernel on a Redox guest
  kernelRebuildTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/kernel-rebuild-test.nix ];
    extraPkgs = extraPkgs // {
      native-kernel-rebuild-bundle = nativeKernelRebuildBundle;
    };
  };
  kernelRebuildTestRaw = mkFunctionalTest {
    diskImage = kernelRebuildTestSystem.diskImage;
    inherit bootloader;
    memoryMB = 8192;
    cpus = 4;
    defaultTimeout = 3600;
  };
  kernelRebuildTest = wrapFunctionalTest {
    base = kernelRebuildTestRaw;
    label = "kernel-rebuild-test";
    auditBundle = nativeKernelRebuildBundle;
    auditCommand = "${auditNativeKernelRebuildBundle}/bin/audit-native-kernel-rebuild-bundle ${nativeKernelRebuildBundle}";
  };

  # Parallel build test: JOBS=1 baseline + JOBS=2 validation
  parallelBuildTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/parallel-build-test.nix ];
    inherit extraPkgs;
  };
  parallelBuildTest = mkFunctionalTest {
    diskImage = parallelBuildTestSystem.diskImage;
    inherit bootloader;
    memoryMB = 4096;
    cpus = 4;
    defaultTimeout = 1800; # graduated workspace tests up to 100 crates — 30 min max
  };

  # Multi-user test: per-user namespaces, file ownership, sudo escalation
  multiUserTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/multi-user-test.nix ];
    inherit extraPkgs;
  };
  multiUserTest = mkFunctionalTest {
    diskImage = multiUserTestSystem.diskImage;
    inherit bootloader;
  };

  # iroh P2P networking test: irohd scheme daemon
  irohTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/iroh-test.nix ];
    inherit extraPkgs;
  };
  irohTest = mkFunctionalTest {
    diskImage = irohTestSystem.diskImage;
    inherit bootloader;
  };

  # Scheme daemon test: stored + profiled daemons serve store: and profile: schemes
  schemeDaemonTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/scheme-daemon-test.nix ];
    inherit extraPkgs;
  };
  schemeDaemonTest = mkFunctionalTest {
    diskImage = schemeDaemonTestSystem.diskImage;
    inherit bootloader;
  };

  # Scheme-native E2E test: daemons auto-start via init, live install/remove
  schemeNativeTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/scheme-native-test.nix ];
    inherit extraPkgs;
  };
  schemeNativeTest = mkFunctionalTest {
    diskImage = schemeNativeTestSystem.diskImage;
    inherit bootloader;
  };

  # Stored lazy extraction test: lazy install, first store: read extracts on demand
  storedLazyTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/stored-lazy-test.nix ];
    inherit extraPkgs;
  };
  storedLazyTest = mkFunctionalTest {
    diskImage = storedLazyTestSystem.diskImage;
    inherit bootloader;
  };

  # Rebuild & generations test: snix system rebuild, generations, rollback
  rebuildGenerationsTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/rebuild-generations-test.nix ];
    inherit extraPkgs;
  };
  rebuildGenerationsTest = mkFunctionalTest {
    diskImage = rebuildGenerationsTestSystem.diskImage;
    inherit bootloader;
    defaultTimeout = 300; # rebuild + rollback may take a while
  };

  bootGenerationSelectTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/boot-generation-select-test.nix ];
    inherit extraPkgs;
  };
  bootGenerationSelectTest = mkFunctionalTest {
    diskImage = bootGenerationSelectTestSystem.diskImage;
    inherit bootloader;
    defaultTimeout = 120;
  };

  # E2E rebuild test: full activate pipeline (etc files, activation scripts, no-op, rollback)
  e2eRebuildTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/e2e-rebuild-test.nix ];
    inherit extraPkgs;
  };
  e2eRebuildTest = mkFunctionalTest {
    diskImage = e2eRebuildTestSystem.diskImage;
    inherit bootloader;
    defaultTimeout = 300;
  };

  # Focused rebuild artifact test: generation dir + metadata + /nix/system/current
  rebuildArtifactsTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/rebuild-artifacts-test.nix ];
    inherit extraPkgs;
  };
  rebuildArtifactsTest = mkFunctionalTest {
    diskImage = rebuildArtifactsTestSystem.diskImage;
    inherit bootloader;
    defaultTimeout = 180;
  };

  # Activate toplevel test: /etc/static, /run/current-system, GC roots
  activateToplevelTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/activate-toplevel-test.nix ];
    inherit extraPkgs;
  };
  activateToplevelTest = mkFunctionalTest {
    diskImage = activateToplevelTestSystem.diskImage;
    inherit bootloader;
    defaultTimeout = 300;
  };

  mkBridgeTest = modularPkgs.infrastructure.mkBridgeTest;
  bridgeTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/bridge-test.nix ];
    inherit extraPkgs;
  };
  bridgeTest = mkBridgeTest {
    diskImage = bridgeTestSystem.diskImage;
    inherit pushToRedox;
  };

  # Bridge rebuild test: end-to-end with REAL build-bridge daemon
  mkBridgeRebuildTest = modularPkgs.infrastructure.mkBridgeRebuildTest;
  bridgeRebuildTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/bridge-rebuild-test.nix ];
    inherit extraPkgs;
  };
  bridgeRebuildTest = mkBridgeRebuildTest {
    diskImage = bridgeRebuildTestSystem.diskImage;
    inherit buildBridge;
  };

  # HTTPS upstream cache test: tests snix fetch from cache.nixos.org over TLS
  mkHttpsCacheTest = modularPkgs.infrastructure.mkHttpsCacheTest;
  httpsCacheTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/https-cache-test.nix ];
    inherit extraPkgs;
  };
  httpsCacheTest = mkHttpsCacheTest {
    diskImage = httpsCacheTestSystem.diskImage;
    inherit bootloader;
  };

  # Standalone HTTP cache server
  serveCache = modularPkgs.infrastructure.serveCache;

  # redox-rebuild CLI tool
  redoxRebuild = import ../pkgs/infrastructure/redox-rebuild.nix {
    inherit pkgs lib;
  };

  # Build bridge: host-side tools for live package push
  pushToRedox = import ../pkgs/infrastructure/push-to-redox.nix {
    inherit pkgs lib self;
  };
  buildBridge = import ../pkgs/infrastructure/build-bridge.nix {
    inherit pkgs lib;
  };

in
{
  packages = {
    # Disk images
    redox-default = systems.default.diskImage;
    redox-minimal = systems.minimal.diskImage;
    redox-graphical = systems.graphical.diskImage;
    redox-cloud = systems.cloud-hypervisor.diskImage;
    redox-self-hosting = systems.self-hosting.diskImage;

    # System identity (toplevel)
    redox-default-toplevel = systems.default.toplevel;
    redox-minimal-toplevel = systems.minimal.toplevel;
    redox-graphical-toplevel = systems.graphical.toplevel;
    redox-cloud-toplevel = systems.cloud-hypervisor.toplevel;
    redox-self-hosting-toplevel = systems.self-hosting.toplevel;
    toplevel = systems.default.toplevel;

    # Default profile runners
    run-redox-default = defaultRunners.headless;
    run-redox-default-qemu = defaultQemuRunners.headless;

    # Minimal profile
    run-redox-minimal = minimalRunners.headless;

    # Cloud Hypervisor profile
    run-redox-cloud = cloudRunners.headless;
    run-redox-cloud-net = cloudRunners.withNetwork;

    # Self-hosting profile
    run-redox-self-hosting = selfHostingRunners.headless;
    run-redox-self-hosting-qemu = selfHostingQemuRunners.headless;

    # Shared filesystem (virtio-fs)
    run-redox-shared = sharedFsRunners.withSharedFs;

    # Graphical profile
    run-redox-graphical-desktop = graphicalQemuRunners.graphical;
    run-redox-graphical-headless = graphicalCHRunners.headless;

    # Default: graphical disk image (what `nix build` produces)
    default = systems.graphical.diskImage;

    # Bare metal images
    diskImage-gmktec = systems.bare-metal-gmktec.diskImage;

    # === Backward-compatible aliases ===
    diskImage = systems.default.diskImage;
    diskImageCloudHypervisor = systems.cloud-hypervisor.diskImage;
    diskImageGraphical = systems.graphical.diskImage;

    initfs = systems.default.initfs;
    initfsGraphical = systems.graphical.initfs;

    runQemu = defaultQemuRunners.headless;
    runQemuGraphical = graphicalQemuRunners.graphical;
    runQemuGraphicalHeadless = graphicalQemuRunners.headless;
    inherit bootTest;

    runCloudHypervisor = defaultRunners.headless;
    runCloudHypervisorNet = cloudRunners.withNetwork;
    runCloudHypervisorDev = defaultRunners.withDev;
    runCloudHypervisorShared = sharedFsRunners.withSharedFs;
    setupCloudHypervisorNetwork = defaultRunners.setupNetwork;

    pauseRedox = defaultRunners.pauseVm;
    resumeRedox = defaultRunners.resumeVm;
    snapshotRedox = defaultRunners.snapshotVm;
    infoRedox = defaultRunners.infoVm;
    resizeMemoryRedox = defaultRunners.resizeMemory;

    redox-functional-test = functionalTestSystem.diskImage;
    inherit functionalTest;

    redox-functional-smoke-test = functionalSmokeTestSystem.diskImage;
    inherit functionalSmokeTest;

    redox-network-test = networkTestSystem.diskImage;
    inherit networkTest;

    redox-ssh-test = sshTestSystem.diskImage;
    ssh-test = sshTest;

    redox-network-install-test = networkInstallTestSystem.diskImage;
    inherit networkInstallTest testBinaryCache;

    redox-channel-update-test = channelUpdateTestSystem.diskImage;
    inherit channelUpdateTest channelUpdateCache;

    redox-bridge-test = bridgeTestSystem.diskImage;
    inherit bridgeTest;

    redox-bridge-rebuild-test = bridgeRebuildTestSystem.diskImage;
    inherit bridgeRebuildTest;

    redox-self-hosting-test = selfHostingTestSystem.diskImage;
    self-hosting-test = selfHostingTest;

    native-kernel-rebuild-bundle = nativeKernelRebuildBundle;
    redox-kernel-rebuild-test = kernelRebuildTestSystem.diskImage;
    kernel-rebuild-test = kernelRebuildTest;

    redox-snix-compile-test = snixCompileTestSystem.diskImage;
    snix-compile-test = snixCompileTest;

    snix-sandbox-test = snixSandboxTest;

    redox-parallel-build-test = parallelBuildTestSystem.diskImage;
    parallel-build-test = parallelBuildTest;

    redox-multi-user-test = multiUserTestSystem.diskImage;
    multi-user-test = multiUserTest;

    redox-scheme-daemon-test = schemeDaemonTestSystem.diskImage;
    scheme-daemon-test = schemeDaemonTest;
    redox-iroh-test = irohTestSystem.diskImage;
    iroh-test = irohTest;

    redox-scheme-native-test = schemeNativeTestSystem.diskImage;
    scheme-native-test = schemeNativeTest;
    redox-stored-lazy-test = storedLazyTestSystem.diskImage;
    stored-lazy-test = storedLazyTest;

    redox-rebuild-generations-test = rebuildGenerationsTestSystem.diskImage;
    rebuild-generations-test = rebuildGenerationsTest;

    redox-boot-generation-select-test = bootGenerationSelectTestSystem.diskImage;
    boot-generation-select-test = bootGenerationSelectTest;

    redox-e2e-rebuild-test = e2eRebuildTestSystem.diskImage;
    e2e-rebuild-test = e2eRebuildTest;

    redox-rebuild-artifacts-test = rebuildArtifactsTestSystem.diskImage;
    rebuild-artifacts-test = rebuildArtifactsTest;

    redox-activate-toplevel-test = activateToplevelTestSystem.diskImage;
    activate-toplevel-test = activateToplevelTest;

    redox-https-cache-test = httpsCacheTestSystem.diskImage;
    inherit httpsCacheTest;

    serve-cache = serveCache;

    redox-rebuild = redoxRebuild;
    push-to-redox = pushToRedox;
    build-bridge = buildBridge;
  };

  # Expose the system builder for advanced use
  legacyPackages = {
    inherit (redoxSystemFactory) redoxSystem;
    redoxConfigurations = systems;

    # Build a Redox system from a list of profile modules.
    # Returns { diskImage, initfs, rootTree, vmConfig, ... }
    mkRedoxSystem =
      { modules }:
      mkSystem {
        inherit modules extraPkgs;
      };

    # Create QEMU runner scripts from a system's disk image.
    # Returns { graphical, headless }
    mkQemuRunners =
      {
        diskImage,
        vmConfig ? { },
      }:
      mkQemuRunners {
        inherit diskImage vmConfig;
        inherit bootloader;
      };

    # Create Cloud Hypervisor runner scripts from a system's disk image.
    # Returns { headless, withNetwork, withDev }
    mkCloudHypervisorRunners =
      {
        diskImage,
        vmConfig ? { },
      }:
      mkCHRunners {
        inherit diskImage vmConfig;
      };

    # The bootloader derivation (needed for custom QEMU setups)
    inherit bootloader;
  };
}
