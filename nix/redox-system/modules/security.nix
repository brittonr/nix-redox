# Security Configuration (/security)
#
# Namespace access control, setuid programs, scheme permissions.
# Redox uses scheme-based namespaces (file:, net:, sys:, etc.)
# rather than traditional Unix permissions.

adios:

let
  t = adios.types;

  namespaceAccess = t.enum "NamespaceAccess" [
    "full"
    "read-only"
    "none"
  ];
in

{
  name = "security";

  options = {
    namespaceAccess = {
      type = t.attrsOf namespaceAccess;
      default = {
        "file" = "full";
        "net" = "full";
        "log" = "read-only";
        "sys" = "read-only";
        "display" = "none";
      };
      description = "Per-scheme namespace access level for userspace";
    };
    setuidPrograms = {
      type = t.listOf t.string;
      default = [
        "su"
        "sudo"
        "login"
        "passwd"
      ];
      description = "Programs that receive the setuid bit";
    };
    protectKernelSchemes = {
      type = t.bool;
      default = true;
      description = "Restrict access to kernel schemes (sys:, irq:)";
    };
    requirePasswords = {
      type = t.bool;
      default = false;
      description = "Require non-empty passwords for all non-root users";
    };
    allowRemoteRoot = {
      type = t.bool;
      default = false;
      description = "Allow root login on remote connections";
    };
    defaultRootSchemes = {
      type = t.listOf t.string;
      default = [
        # Kernel schemes
        "debug" "event" "memory" "pipe" "serio" "irq" "time" "sys"
        # Base schemes
        "rand" "null" "zero" "log"
        # Network schemes
        "ip" "icmp" "tcp" "udp"
        # IPC schemes
        "shm" "chan" "uds_stream" "uds_dgram"
        # File schemes
        "file"
        # Display schemes
        "display.vesa" "display*"
        # Other schemes
        "pty" "sudo" "audio"
        # Debugging (root only)
        "proc"
      ];
      description = "Default scheme namespace list for root users (includes kernel-internal schemes)";
    };
    defaultUserSchemes = {
      type = t.listOf t.string;
      default = [
        "debug" "event" "pipe" "time"
        "rand" "null" "zero" "log"
        "ip" "icmp" "tcp" "udp"
        "shm" "chan" "uds_stream" "uds_dgram"
        "file"
        "display.vesa" "display*"
        "pty" "sudo" "audio"
      ];
      description = "Default scheme namespace list for non-root users (excludes irq, sys, memory, serio)";
    };
  };

  impl = { options }: options;
}
