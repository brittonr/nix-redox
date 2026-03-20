# Shared service type definition
#
# Used by any module that declares services. Import with:
#   serviceType = import ../lib/service-type.nix { inherit t; };
# where t = adios.types.

{ t }:

t.struct "Service" {
  # Human-readable description
  description = t.string;
  # Binary or script to execute
  command = t.string;
  # How to start the service:
  #   oneshot  — run and wait for completion
  #   daemon   — start with notify (wait for readiness)
  #   nowait   — start in background
  #   scheme   — scheme daemon (scheme <args> <command>)
  type = t.enum "ServiceType" [
    "oneshot"
    "daemon"
    "nowait"
    "scheme"
  ];
  # Extra arguments (for scheme: the scheme name; for others: CLI args)
  args = t.string;
  # Which init phase should start this service:
  #   initfs  — early boot (before rootfs mount)
  #   rootfs  — after rootfs is mounted
  wantedBy = t.enum "Target" [
    "initfs"
    "rootfs"
  ];
  # Whether the service is enabled
  enable = t.bool;
  # Service names that must start before this one (dependency ordering).
  # The build system topologically sorts services and assigns numeric
  # prefixes to init scripts based on the dependency graph.
  after = t.listOf t.string;
  # Per-service environment variables, rendered as `export KEY VALUE`
  # lines before the service command in the generated init script.
  environment = t.attrsOf t.string;
  # Explicit numeric priority (10-79). When set to a non-default value,
  # overrides auto-numbering from the dependency graph.
  # Default 50 means auto-number from topo sort position.
  priority = t.int;
}
