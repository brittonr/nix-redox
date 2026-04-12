# Cross-module assertions and warnings
# Validates configuration invariants that Korora types alone can't express.
# Inspired by nix-darwin's assertions system.

{ lib, cfg, inputs, pkgs }:

let
  # ===== ASSERTIONS (cross-module validation) =====
  # Inspired by nix-darwin's assertions system.
  # Checks invariants across modules that Korora types alone can't express.
  assertions = [
    {
      assertion = !cfg.graphicsEnabled || (pkgs ? orbital);
      message = "graphics.enable requires the 'orbital' package. Add it to pkgs or disable graphics.";
    }
    {
      assertion =
        !(cfg.networkingEnabled && (inputs.networking.mode or "auto") == "static")
        || (inputs.networking.interfaces or { } != { });
      message = "networking.mode = 'static' requires at least one interface in networking.interfaces.";
    }
    {
      # vesad (UEFI GOP framebuffer) is always loaded when graphics is enabled,
      # so an empty graphicsDrivers list is valid for bare metal (no PCI GPU driver needed).
      assertion =
        !cfg.graphicsEnabled
        || (inputs.hardware.graphicsDrivers or [ ]) == [ ]
        || builtins.any (d: d == "virtio-gpud" || d == "bgad") (inputs.hardware.graphicsDrivers or [ ]);
      message = "graphics.enable is set but graphicsDrivers contains unrecognized drivers. Use [] for vesad-only (bare metal) or include virtio-gpud/bgad for VMs.";
    }
    {
      assertion = cfg.diskSizeMB > cfg.espSizeMB;
      message = "boot.diskSizeMB (${toString cfg.diskSizeMB}) must be greater than boot.espSizeMB (${toString cfg.espSizeMB}).";
    }
    {
      assertion = cfg.diskSizeMB - cfg.espSizeMB >= 16;
      message = "RedoxFS partition must be at least 16MB. Increase diskSizeMB or decrease espSizeMB.";
    }
    {
      assertion = builtins.all (user: (user.uid or 0) >= 0) (lib.attrValues (inputs.users.users or { }));
      message = "All user UIDs must be non-negative.";
    }
    # New module assertions
    {
      assertion = !(cfg.ntpEnabled && !cfg.networkingEnabled);
      message = "time.ntpEnable requires networking.enable = true.";
    }
    {
      assertion =
        !cfg.requirePasswords
        || builtins.all (user: (user.uid or 0) == 0 || (user.password or "") != "") (
          lib.attrValues (inputs.users.users or { })
        );
      message = "security.requirePasswords is set but some non-root users have empty passwords.";
    }
    {
      assertion = (inputs.logging.maxLogSizeMB or 10) > 0;
      message = "logging.maxLogSizeMB must be positive.";
    }
    {
      assertion = (inputs.power.idleTimeoutMinutes or 30) > 0;
      message = "power.idleTimeoutMinutes must be positive.";
    }
    # Boot-essential packages must include base (init, logd, ipcd, ptyd).
    {
      assertion = pkgs ? base;
      message = "pkgs.base is missing. Init daemons (init, logd, ipcd, ptyd) would be absent from /bin/.";
    }
    # Typed service module assertions
    {
      assertion = !cfg.sshEnabled || cfg.sshPackageInstalled;
      message = "services.ssh.enable requires the 'openssh' package in environment.systemPackages.";
    }
    {
      assertion = !cfg.sshEnabled || cfg.networkingEnabled;
      message = "services.ssh.enable requires networking.enable = true.";
    }
    {
      assertion = !cfg.svcHttpdEnabled || cfg.networkingEnabled;
      message = "services.httpd.enable requires networking.enable = true.";
    }
    {
      assertion =
        inputs.services.getty.enable == "auto" || inputs.services.getty.enable == "false" || (pkgs ? userutils);
      message = "services.getty.enable = 'true' requires the 'userutils' package in pkgs.";
    }
    {
      assertion = !inputs.services.exampled.enable || (pkgs ? exampled);
      message = "services.exampled.enable requires the 'exampled' package in pkgs.";
    }
    {
      assertion = !inputs.snix.stored.enable || (pkgs ? stored);
      message = "snix.stored.enable requires the 'stored' package in pkgs.";
    }
    {
      assertion =
        !inputs.snix.stored.enable
        || builtins.any (p: toString p == toString pkgs.stored) (inputs.environment.systemPackages or [ ]);
      message = "snix.stored.enable requires the 'stored' package in environment.systemPackages.";
    }
    {
      assertion = !(inputs.audio.enable or false) || cfg.audioEnabled;
      message = "audio.enable requires hardware.audioEnable = true for audio drivers (ihdad, ac97d, sb16d).";
    }
    {
      assertion =
        !(inputs.boot.kernelSyscallDebugProcesses or [ ] != [ ])
        || (inputs.boot.kernelSyscallDebug or false);
      message = "boot.kernelSyscallDebugProcesses is set but boot.kernelSyscallDebug is not enabled.";
    }
  ];

  # Warnings: non-fatal notices traced during evaluation
  warnings = builtins.filter (w: w != "") [
    (lib.optionalString (cfg.graphicsEnabled && !cfg.audioEnabled)
      "Graphics is enabled but audio is not. Consider setting hardware.audioEnable = true for a complete desktop experience."
    )
    (lib.optionalString (cfg.diskSizeMB < 256) "Disk size is less than 256MB. Some packages may not fit.")
    (lib.optionalString (
      cfg.ntpEnabled && (inputs.time.ntpServers or [ ]) == [ ]
    ) "NTP is enabled but no NTP servers configured.")
    (lib.optionalString (
      !cfg.protectKernelSchemes
    ) "Kernel scheme protection is disabled. This may expose system internals to userspace.")
    (lib.optionalString (
      cfg.allowRemoteRoot && cfg.networkingEnabled
    ) "Remote root login is allowed with networking enabled. Consider disabling for production.")
    (lib.optionalString (
      cfg.sshEnabled && cfg.sshOpts.permitRootLogin
    ) "SSH root login is permitted. Consider services.ssh.permitRootLogin = false for production.")
    (lib.optionalString (
      inputs.boot.kernelSyscallDebug or false
    ) "Kernel syscall tracing is enabled. All syscalls are printed to serial — expect heavy output and slower performance.")
  ];

  # Process assertions — throw at eval time if any fail
  failedAssertions = builtins.filter (a: !a.assertion) assertions;
  assertionCheck =
    if failedAssertions != [ ] then
      throw "\nFailed assertions:\n${
        lib.concatStringsSep "\n" (map (a: "- ${a.message}") failedAssertions)
      }"
    else
      true;

  # Process warnings — trace non-empty ones
  warningCheck = lib.foldr (w: x: builtins.trace "warning: ${w}" x) true warnings;

in

{
  inherit
    assertions
    warnings
    assertionCheck
    warningCheck
    ;
}