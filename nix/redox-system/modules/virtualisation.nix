# Virtualisation Configuration (/virtualisation)
#
# VMM backend selection, resource allocation, and runtime settings.
# Inspired by NixBSD's virtualisation/qemu-vm.nix module.
#
# This is a pure configuration module — it produces no derivations.
# The build module and flake runner factories consume these options
# to configure VM execution.

adios:

let
  t = adios.types;

  vmmType = t.enum "VMM" [
    "cloud-hypervisor"
    "qemu"
  ];
in

{
  name = "virtualisation";

  options = {
    # VMM backend
    vmm = {
      type = vmmType;
      default = "cloud-hypervisor";
      description = "Virtual machine monitor backend";
    };

    # Resources
    memorySize = {
      type = t.int;
      default = 2048;
      description = "Memory size in megabytes";
    };
    cpus = {
      type = t.int;
      default = 4;
      description = "Number of virtual CPUs";
    };

    # Display
    graphics = {
      type = t.bool;
      default = false;
      description = "Enable graphical display (QEMU only)";
    };
    serialConsole = {
      type = t.bool;
      default = true;
      description = "Enable serial console output";
    };

    # Disk
    useCoW = {
      type = t.bool;
      default = true;
      description = "Use copy-on-write overlay for ephemeral disk changes";
    };

    # Cloud Hypervisor specific
    hugepages = {
      type = t.bool;
      default = false;
      description = "Use hugepages for guest memory (Cloud Hypervisor)";
    };
    directIO = {
      type = t.bool;
      default = true;
      description = "Use direct I/O for disk access (Cloud Hypervisor)";
    };
    apiSocket = {
      type = t.bool;
      default = false;
      description = "Enable API socket for runtime control (Cloud Hypervisor)";
    };

    # Networking
    tapNetworking = {
      type = t.bool;
      default = false;
      description = "Use TAP networking instead of user-mode (requires setup)";
    };

    # QEMU specific
    qemuExtraArgs = {
      type = t.listOf t.string;
      default = [ ];
      description = "Extra command-line arguments for QEMU";
    };
  };

  impl = { options }: options;
}
