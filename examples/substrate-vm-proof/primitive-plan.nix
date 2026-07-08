# Public Redox substrate VM proof primitive plan.
# This fixture is intentionally frontend-shaped: it uses only the public
# substrate primitive plan surface, not Adios path-keyed modules.

let
  receipt = {
    machine = "redoxvm";
    machine_class = "onixos";
    substrate = "redox";
    descriptor_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
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
  runtimeStatus = {
    schema = "onixos-redox-runtime-status-v1";
    schema_version = 1;
    machine = receipt.machine;
    system = "x86_64-linux";
    machine_class = receipt.machine_class;
    substrate = receipt.substrate;
    redox_target = "vm";
    descriptor_hash = receipt.descriptor_hash;
    materialization_refs = receipt.materialization_refs;
    status_source_path = receipt.receipt_path;
    status_entrypoint = receipt.status_entrypoint;
    receipt_path = receipt.receipt_path;
    runtime_owner = "redox-guest:${receipt.status_entrypoint}";
    runtime_owned = true;
    host_copied = false;
    nix_runtime_fallback = false;
    freshness = {
      boot_id = receipt.boot_id;
      boot_sequence = receipt.freshness_ref;
      fresh = true;
    };
    service_states = receipt.service_states;
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

  filesystem.files."onixos/runtime-status.json" = {
    text = builtins.toJSON runtimeStatus;
    mode = "0644";
  };

  image = {
    diskImage = true;
    initfs = true;
    vmRunner = "qemu";
  };
}
