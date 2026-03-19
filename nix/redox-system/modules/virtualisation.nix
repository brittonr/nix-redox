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
      default = true;
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
    qemuNicModel = {
      type = t.enum "NicModel" [
        "e1000"
        "virtio-net-pci"
      ];
      default = "virtio-net-pci";
      description = "QEMU NIC device model (virtio-net-pci for performance, e1000 for broad compatibility)";
    };
    qemuHostSshPort = {
      type = t.int;
      default = 8022;
      description = "Default host port forwarded to guest SSH (port 22) in QEMU user-mode networking";
    };
    qemuHostHttpPort = {
      type = t.int;
      default = 8080;
      description = "Default host port forwarded to guest HTTP (port 80) in QEMU user-mode networking";
    };
    qemuExtraArgs = {
      type = t.listOf t.string;
      default = [ ];
      description = "Extra command-line arguments for QEMU";
    };

    # Cloud Hypervisor specific
    cpuTopology = {
      type = t.string;
      default = "1:2:1:2";
      description = "CPU topology for Cloud Hypervisor (threads_per_core:cores_per_die:dies_per_package:packages). Default: 2 sockets with 2 cores each = 4 vCPUs";
    };
    chMinTimeout = {
      type = t.int;
      default = 180;
      description = "Minimum timeout floor (seconds) applied when auto-selecting Cloud Hypervisor for tests";
    };
    chNetQueues = {
      type = t.int;
      default = 2;
      description = "Number of virtio-net queues for Cloud Hypervisor (2 = 1 RX + 1 TX, multi-queue requires IFF_MULTI_QUEUE TAP)";
    };
    chNetQueueSize = {
      type = t.int;
      default = 256;
      description = "Size of each virtio-net queue for Cloud Hypervisor";
    };
    chApiSocketPath = {
      type = t.string;
      default = "/tmp/cloud-hypervisor-redox.sock";
      description = "Unix socket path for Cloud Hypervisor API (runtime control: pause/resume/snapshot)";
    };

    # TAP networking
    tapInterface = {
      type = t.string;
      default = "tap0";
      description = "TAP interface name for VM networking (Cloud Hypervisor TAP mode)";
    };
    hostIp = {
      type = t.string;
      default = "172.16.0.1";
      description = "Host-side IP address on the TAP interface";
    };
    guestIp = {
      type = t.string;
      default = "172.16.0.2";
      description = "Guest IP address (used for static network config in TAP mode)";
    };
    guestNetmask = {
      type = t.string;
      default = "24";
      description = "Guest network mask (CIDR prefix length)";
    };
    guestSubnet = {
      type = t.string;
      default = "172.16.0.0/24";
      description = "Subnet for TAP networking (used in NAT/masquerade rules)";
    };
    guestMac = {
      type = t.string;
      default = "52:54:00:12:34:56";
      description = "Guest MAC address for TAP networking";
    };

    # Shared filesystem (virtio-fs)
    sharedFsDir = {
      type = t.string;
      default = "/tmp/redox-shared";
      description = "Host directory shared with the guest via virtio-fs";
    };
    sharedFsTag = {
      type = t.string;
      default = "shared";
      description = "Tag name for the virtio-fs mount (guest sees /scheme/<tag>)";
    };
    sharedFsNumQueues = {
      type = t.int;
      default = 1;
      description = "Number of virtio-fs queues for Cloud Hypervisor shared filesystem";
    };
    sharedFsQueueSize = {
      type = t.int;
      default = 512;
      description = "Size of each virtio-fs queue for Cloud Hypervisor shared filesystem";
    };
    virtiofsdCacheMode = {
      type = t.enum "VirtiofsdCacheMode" [
        "auto"
        "always"
        "never"
      ];
      default = "auto";
      description = "virtiofsd cache policy (auto=metadata+content, always=aggressive, never=no caching)";
    };

    # Cloud Hypervisor platform
    chPciSegments = {
      type = t.int;
      default = 1;
      description = "Number of PCI segments for Cloud Hypervisor (--platform num_pci_segments)";
    };
    chMmio32ApertureWeight = {
      type = t.int;
      default = 4;
      description = "32-bit MMIO aperture weight for Cloud Hypervisor PCI segment 0";
    };
    chMemoryHotplugSizeMB = {
      type = t.int;
      default = 2048;
      description = "Memory hotplug pool size in megabytes for Cloud Hypervisor dev mode";
    };

    # QEMU specific
    qemuMachineType = {
      type = t.string;
      default = "pc";
      description = "QEMU machine type (-M flag). Use 'pc' for i440FX or 'q35' for ICH9/PCIe";
    };
    qemuExpectTimeout = {
      type = t.int;
      default = 120;
      description = "Expect timeout (seconds) for QEMU graphical mode resolution auto-selection";
    };
  };

  impl = { options }: options;
}
