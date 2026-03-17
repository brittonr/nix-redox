## 1. Service diff unit tests in activate.rs

- [x] 1.1 Test: ActivationPlan computes services_added when new manifest has a service not in old
- [x] 1.2 Test: ActivationPlan computes services_removed when old manifest has a service not in new
- [x] 1.3 Test: Unchanged services appear in neither added nor removed
- [x] 1.4 Test: reboot_recommended is true when services are added or removed

## 2. Boot path change detection in activate.rs

- [x] 2.1 Test: has_boot_config_changed returns true when initfs path differs
- [x] 2.2 Test: has_boot_config_changed returns false when boot paths are identical

## 3. Nonexistent package handling in rebuild.rs

- [x] 3.1 Test: resolve_packages_from_json returns empty store_path for unknown package name
- [x] 3.2 Test: merge_config with unresolved package (empty store_path) includes it in merged manifest
- [x] 3.3 Test: merge_config preserves boot-essential packages even when all resolved packages are empty

## 4. Spec coverage verification

- [x] 4.1 Run full test suite, confirm all existing + new tests pass (607 pass)
- [x] 4.2 Map each spec scenario to its covering test — see below

### Spec Coverage Map

| Spec Scenario | Covering Test |
|---|---|
| Show config on booted system | integration: `show-config-runs`, `show-config-has-hostname` |
| Dry-run with unchanged config | integration: `rebuild-dryrun-succeeds`, `dryrun-no-change` |
| Dry-run with hostname change | integration: `config-modified` + `rebuild-dryrun-succeeds` |
| Activation plan shows service-level diffs | unit: `plan_service_add_remove_unchanged_stays_out` |
| Reboot recommended after boot path change | unit: `has_boot_config_changed_on_initfs_path_diff` |
| Rebuild with hostname change | integration: `rebuild-succeeds`, `hostname-updated`, `manifest-hostname-updated`, `generations-created` |
| Rebuild with driver change via bridge | integration: covered by bridge-rebuild-test profile |
| Rebuild with driver change without bridge | unit: `has_boot_affecting_changes` tests + auto_rebuild error path |
| Rebuild with package addition via bridge | integration: `pkg-rebuild-succeeds`, `pkg-in-manifest` |
| Rebuild with nonexistent package via local | unit: `test_resolve_packages_missing`, `test_merge_unresolved_package_included_in_manifest` |
| First rebuild creates generation | integration: `generations-has-gen2`, `generation-ids-monotonic` |
| Rebuild saves boot paths in pre-rebuild gen | integration: `gen1-boot-path-preserved`, `boot-kernel-path`, `boot-initfs-path` |
| Auto-route detects driver change | unit: `test_storage_drivers_alone_triggers_boot_affecting`, `test_needs_bridge_hardware_only` |
| Auto-route allows local for config-only | integration: `auto-route-config-only` |
| Configuration.nix exists on booted systems | integration: `config-nix-exists` |
