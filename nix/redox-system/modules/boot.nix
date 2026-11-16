# Boot Configuration (/boot)
#
# Kernel, bootloader, and initfs settings.

adios:

let
  t = adios.types;
in

{
  name = "boot";

  inputs = {
    pkgs = {
      path = "/pkgs";
    };
  };

  options = {
    kernel = {
      # attrs not derivation: defaultFunc may return {} when package missing
      type = t.attrs;
      defaultFunc = { inputs }: inputs.pkgs.pkgs.kernel or { };
      description = "Kernel package";
    };
    bootloader = {
      # attrs rather than derivation permits lightweight package injection.
      type = t.attrs;
      defaultFunc = { inputs, options }:
        let
          variant =
            if options.liveMode then
              if options.autoBoot then "bootloaderLiveAutoboot" else "bootloaderLive"
            else
              if options.autoBoot then "bootloaderAutoboot" else "bootloader";
        in
        inputs.pkgs.pkgs.${variant}
          or (throw "boot: required ${variant} package is missing (liveMode=${builtins.toJSON options.liveMode}, autoBoot=${builtins.toJSON options.autoBoot})");
      description = ''
        Bootloader package selected independently by liveMode and autoBoot.
        An explicit package override takes precedence over both options and
        must implement the requested storage and selection behavior itself.
      '';
    };
    bootProof = {
      type = t.bool;
      default = false;
      description = "Emit executing initfs identity before switchroot for the native cold-boot proof";
    };
    initfsExtraBinaries = {
      type = t.listOf t.string;
      default = [ ];
      description = "Extra binaries to include in initfs";
    };
    initfsExtraDrivers = {
      type = t.listOf t.string;
      default = [ ];
      description = "Extra drivers to include in initfs";
    };
    initfsEnableGraphics = {
      type = t.bool;
      default = false;
      description = "Enable graphics in initfs (vesad, inputd, ps2d)";
    };
    diskSizeMB = {
      type = t.int;
      default = 896;
      description = "Disk image size in megabytes";
    };
    espSizeMB = {
      type = t.int;
      default = 200;
      description = "EFI System Partition size in megabytes";
    };
    espLabel = {
      type = t.string;
      default = "EFI";
      description = "FAT32 volume label for the EFI System Partition";
    };
    initfsSizeMB = {
      type = t.int;
      default = 64;
      description = "Maximum initfs image size in megabytes (default 64 MiB)";
    };
    initfsPrompt = {
      type = t.string;
      default = "ion> ";
      description = "Shell prompt used in the initfs environment (before rootfs mount)";
    };
    rustBacktrace = {
      type = t.enum "RustBacktrace" [
        "0"
        "1"
        "full"
      ];
      default = "1";
      description = "RUST_BACKTRACE value for initfs daemons (0=off, 1=basic, full=verbose)";
    };
    essentialPackages = {
      type = t.listOf t.derivation;
      default = [ ];
      description = "Extra packages to include as boot-essential (flat-copied to /bin/, survive generation switches)";
    };
    kernelSyscallDebug = {
      type = t.bool;
      default = false;
      description = ''
        Build the kernel with syscall_debug feature enabled and the
        default process filter removed. When true, ALL syscalls from
        ALL processes are traced to the serial console. Use
        kernelSyscallDebugProcesses to limit tracing to specific
        programs. See also strace-redox for userspace tracing.
      '';
    };
    kernelSyscallDebugProcesses = {
      type = t.listOf t.string;
      default = [ ];
      description = ''
        Process names to trace (matched with contains()). Empty list
        means trace everything. Examples: ["cargo"] ["snix" "rustc"].
        Only effective when kernelSyscallDebug is true.
      '';
    };
    banner = {
      type = t.string;
      default = ''
        ==========================================
          Redox OS Boot Complete!
        ==========================================
      '';
      description = "Banner text displayed on serial console after boot completes";
    };
    initfsExcludeDaemons = {
      type = t.listOf t.string;
      default = [ ];
      description = "Daemons to exclude from the default initfs set (e.g. [\"rtcd\" \"hwd\"] for minimal configs)";
    };
    initfsScripts = {
      type = t.attrsOf t.string;
      default = { };
      description = "Override individual initfs init.d scripts by name (e.g. \"00_runtime\", \"90_exit_initfs\"). Content replaces the default script entirely.";
    };
    autoLogin = {
      type = t.string;
      default = "";
      description = ''
        Username to auto-login as on the console. When non-empty,
        getty's -C flag is used to run a contain_login wrapper that
        skips the login prompt and directly spawns the user's shell.
        Empty string (default) means normal interactive login.
      '';
    };
    autoBoot = {
      type = t.bool;
      defaultFunc = { options }: options.liveMode;
      description = ''
        Skip the graphical bootloader's interactive resolution/mode menu.
        Does not enable live filesystem loading or change persistence.
        Defaults to liveMode, preserving unattended live-image behavior and
        interactive ordinary disk boot. Set explicitly to decouple selection
        from storage: true with liveMode=false boots unattended from disk;
        false with liveMode=true retains the interactive live menu.
        Serial-only firmware may bypass the graphical menu in either mode.
      '';
    };
    liveMode = {
      type = t.bool;
      default = false;
      description = ''
        Build for live disk boot (USB stick, JetKVM virtual media).
        The entire disk image is loaded into RAM by the bootloader.
        lived provides a COW overlay so writes go to memory, not disk.
        When true, storage drivers (nvmed, ahcid) are excluded from
        initfs since the rootfs is served from RAM, not a real disk.
        Defaults autoBoot to true for compatibility; an explicit autoBoot
        value controls menu selection independently. The interactive menu's
        upstream 'l' key can still toggle live loading for that boot only;
        it does not regenerate initfs or restore omitted storage drivers.
      '';
    };
    initDebug = {
      type = t.bool;
      default = false;
      description = ''
        Enable init debug logging. When true, sets INIT_LOG_LEVEL=DEBUG
        in init's process environment via bootstrap, causing init to log
        every service spawn, script command, and target transition to the
        serial console.
      '';
    };
    initSkip = {
      type = t.listOf t.string;
      default = [ ];
      description = ''
        List of init command names to skip during boot. Sets INIT_SKIP
        in init's process environment via bootstrap. Each entry is
        matched against the cmd field of services. Examples:
        ["hwd"] ["hwd" "pcid-spawner"].
      '';
    };
  };

  impl = { options }: options;
}
