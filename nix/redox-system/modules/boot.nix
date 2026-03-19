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
      # attrs not derivation: defaultFunc may return {} when package missing
      type = t.attrs;
      defaultFunc = { inputs }: inputs.pkgs.pkgs.bootloader or { };
      description = "Bootloader package";
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
      default = 768;
      description = "Disk image size in megabytes";
    };
    espSizeMB = {
      type = t.int;
      default = 200;
      description = "EFI System Partition size in megabytes";
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
  };

  impl = { options }: options;
}
