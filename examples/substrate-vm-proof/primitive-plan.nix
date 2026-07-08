# Public Redox substrate VM proof primitive plan.
# This fixture is intentionally frontend-shaped: it uses only the public
# substrate primitive plan surface, not Adios path-keyed modules.

let
  receipt = {
    machine = "redoxvm";
    machine_class = "onixos";
    substrate = "redox";
    descriptor_hash = "redox-substrate-vm-proof-fixture";
    materialization_refs = [
      "export/initfs"
      "export/kernel"
      "export/redoxfs.img"
    ];
    status_entrypoint = "/bin/onixos-status";
    receipt_path = "/run/onixos/status.json";
    service_states = [
      "boot-receipt=declared"
      "onixos-status-file=declared"
    ];
    freshness_ref = "redox-boot-banner";
    boot_id = "redoxvm-repo-owned-qemu-boot";
    source = "redox-boot-banner";
    runtime_owned = true;
    nix_runtime_fallback = false;
  };
in
{
  services.boot_receipt = {
    description = "OnixOS/Redox VM boot receipt service";
    command = "/bin/ion";
    argv = [
      "-c"
      "echo onixos-redox-vm-boot-proof"
    ];
    type = "oneshot";
    wantedBy = "rootfs";
    priority = 90;
  };

  filesystem.files."onixos/status.json" = {
    text = builtins.toJSON receipt;
    mode = "0644";
  };

  image = {
    diskImage = true;
    initfs = true;
    vmRunner = "qemu";
  };
}
