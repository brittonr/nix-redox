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
  };

  impl = { options }: options;
}
