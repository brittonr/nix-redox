# Evidence — nix-self-hosting-roadmap

## 0. Prerequisites

This section references archived evidence; it does not duplicate those artifacts into this active change directory.

### 0.1 `stabilize-self-hosting-baseline` exit criteria met
- Archived change: `openspec/changes/archive/2026-04-07-stabilize-self-hosting-baseline/`
- Task record: `openspec/changes/archive/2026-04-07-stabilize-self-hosting-baseline/tasks.md`

### 0.2 `fix-snix-build-gaps` tasks updated to the post-rollback failure set
- Archived change: `openspec/changes/archive/2026-04-09-fix-snix-build-gaps/`
- Task record: `openspec/changes/archive/2026-04-09-fix-snix-build-gaps/tasks.md`
- Evidence index: `openspec/changes/archive/2026-04-09-fix-snix-build-gaps/evidence/README.md`

## 1. VM validation baseline

This section references archived evidence; it does not duplicate those artifacts into this active change directory.

Tasks `1.1` through `1.9` are backed by the archived self-hosting reruns and evidence from:
- `openspec/changes/archive/2026-04-09-fix-snix-build-gaps/tasks.md`
- `openspec/changes/archive/2026-04-09-fix-snix-build-gaps/evidence/README.md`
- `openspec/changes/archive/2026-04-09-resolve-libmimalloc-sys-redox/evidence/2026-04-09-snix-compile-focus-pass.excerpt.txt`

The archived evidence captures:
- focused `snix-compile-test` pass
- focused `snix-sandbox-test` pass
- full `self-hosting-test` pass (`78/78`)

## 2. Remote binary cache client

### 2.1–2.7 host-side implementation + validation
Implementation files:
- `snix-redox/Cargo.toml`
- `snix-redox/Cargo.lock`
- `snix-redox/src/cache_source.rs`
- `snix-redox/src/install.rs`
- `snix-redox/src/main.rs`
- `snix-redox/src/rebuild.rs`
- `snix-redox/build-plan.json`
- `nix/pkgs/userspace/snix-build-plan.json`

Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-10-snix-remote-cache-host-validation.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-10-snix-remote-cache-host-validation.excerpt.txt`

Command:
- `./scripts/validate-snix-redox-host.sh`

Key result from the log:
- `cargo test --lib --target x86_64-unknown-linux-gnu`: `587 passed; 0 failed`
- `cargo test --lib --target x86_64-unknown-linux-gnu: PASS`
- `cargo check --bins --target x86_64-unknown-linux-gnu: PASS`

This log records the host-side validation command after regenerating both unit2nix build plans, including explicit PASS markers for `cargo test --lib` and `cargo check --bins`.

### 2.8 VM test: install from remote cache over HTTP
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-10-network-install-test.log`

Command:
- `nix run .#network-install-test -- --verbose`

Task-specific expected URL/port:
- `http://10.0.2.2:8080`

Key result from the log:
- `FUNC_TEST:net-install-ripgrep:PASS`
- `FUNC_TEST:net-ripgrep-runs:PASS`
- overall summary: `Total: 10 | Pass: 10 | Fail: 0 | Skip: 0`

The HTTP server section of the same log shows the guest fetched the remote cache index plus the corresponding `.narinfo` and `.nar.zst` artifacts over port 8080.

## 4. Full guest rebuild flow

### 4.5 reboot-recommended warning on boot-component change
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-rebuild-artifacts-test.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-rebuild-artifacts-test.excerpt.txt`

Command:
- `nix run .#rebuild-artifacts-test -- --verbose`

Key result from the log:
- `FUNC_TEST:boot-manifest-modified:PASS`
- `FUNC_TEST:reboot-warning-reported:PASS`
- `FUNC_TEST:auto-route-package-rebuild:PASS`
- `FUNC_TEST:auto-route-package-profile:PASS`
- `FUNC_TEST:auto-route-package-manifest:PASS`
- overall summary: `Passed: 17`, `Failed: 0`

Support files wired into the flake:
- `nix/redox-system/profiles/rebuild-artifacts-test.nix`
- `nix/flake-modules/system.nix`
- `nix/flake-modules/apps.nix`
- `nix/flake-modules/checks.nix`

### 4.6 generated test configuration.nix on self-hosting images
Implementation file:
- `nix/redox-system/modules/build/generated-files.nix`

Key implementation point:
- `generated-files.nix` emits `etc/redox-system/configuration.nix` from the shared `mkSystem` image-generation path, so self-hosting profiles inherit the same editable rebuild config on disk.

Corroborating runtime smoke from rebuild test images:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-e2e-rebuild-test.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-rebuild-artifacts-test.log`

Key result from those logs:
- `FUNC_TEST:config-modified:PASS`
- focused rebuild VMs successfully edit `/etc/redox-system/configuration.nix` before invoking `snix system rebuild`

## 5. Generation management follow-up

### 5.1 generations host validation
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-generations-host-validation.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-generations-host-validation.excerpt.txt`

Command:
- `cd snix-redox && PROTO_ROOT=$PWD/upstream PROTOC=$(command -v protoc) cargo test --lib --target x86_64-unknown-linux-gnu generations_`

Key result from the log:
- `test system::tests::scan_generations_empty_dir ... ok`
- `test system::tests::scan_generations_nonexistent_dir ... ok`
- `test system::tests::scan_generations_finds_numbered_dirs ... ok`
- `test system::tests::scan_generations_skips_non_numeric_dirs ... ok`
- `test system::tests::scan_generations_sorted ... ok`
- `test system::tests::generations_with_stored_gens ... ok`
- overall summary: `14 passed; 0 failed`

Related guest-side coverage:
- `nix/redox-system/test-scripts/07-manifest.ion` checks `snix system generations` runs, prints the header, and reports stored-generation count
- `nix/redox-system/profiles/rebuild-generations-test.nix` checks generation listing after rebuild and verifies generation `2` appears in the output

### 5.2 switch-generation host validation
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-switch-generation-host-validation.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-switch-generation-host-validation.excerpt.txt`

Command:
- `cd snix-redox && PROTO_ROOT=$PWD/upstream PROTOC=$(command -v protoc) cargo test --lib --target x86_64-unknown-linux-gnu switch_generation_`

Key result from the log:
- `test system::tests::switch_generation_missing_generation_errors ... ok`
- `test system::tests::switch_generation_updates_target_etc_files_via_activation ... ok`
- `test system::tests::switch_generation_activates_existing_generation ... ok`
- overall summary: `3 passed; 0 failed`

### 5.3 rollback host validation
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-rollback-host-validation.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-rollback-host-validation.excerpt.txt`

Command:
- `cd snix-redox && PROTO_ROOT=$PWD/upstream PROTOC=$(command -v protoc) cargo test --lib --target x86_64-unknown-linux-gnu rollback_`

Key result from the log:
- `test system::tests::rollback_same_id_noop ... ok`
- `test system::tests::rollback_no_generations_errors ... ok`
- `test system::tests::rollback_with_gc_roots_resilient ... ok`
- `test system::tests::rollback_restores_previous ... ok`
- `test system::tests::rollback_increments_id ... ok`
- overall summary: `5 passed; 0 failed`

Related guest-side coverage:
- `nix/redox-system/profiles/rebuild-generations-test.nix` exercises rollback success, hostname restoration, new-generation creation, and rollback manifest matching
- `nix/redox-system/test-scripts/21-e2e-rebuild.ion` exercises rollback success, hostname restoration, and rollback generation growth in the live rebuild cycle

### 5.4 delete-generations host validation
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-delete-generations-host-validation.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-delete-generations-host-validation.excerpt.txt`

Command:
- `cd snix-redox && PROTO_ROOT=$PWD/upstream PROTOC=$(command -v protoc) cargo test --lib --target x86_64-unknown-linux-gnu delete_generations_`

Key result from the log:
- `test system::tests::delete_generations_by_id ... ok`
- `test system::tests::delete_generations_keep_last_n ... ok`
- `test system::tests::delete_generations_old ... ok`
- `test system::tests::delete_generations_protects_current ... ok`
- `test system::tests::delete_generations_protects_boot_default ... ok`
- `test system::tests::delete_generations_dry_run ... ok`
- `test system::tests::delete_generations_nothing_to_delete ... ok`
- `test system::tests::delete_generations_older_than_days ... ok`
- overall summary: `8 passed; 0 failed`

Related guest-side coverage:
- `nix/redox-system/test-scripts/09-generations.ion` exercises dry-run reporting, current-generation protection, by-ID deletion, `+N` pruning, `old` pruning, and GC-root cleanup after deletion

### 5.5 age-pruning host validation
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-age-pruning-host-validation.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-age-pruning-host-validation.excerpt.txt`

Commands:
- `cd snix-redox && PROTO_ROOT=$PWD/upstream PROTOC=$(command -v protoc) cargo test --lib --target x86_64-unknown-linux-gnu delete_generations_older_than_days`
- `cd snix-redox && PROTO_ROOT=$PWD/upstream PROTOC=$(command -v protoc) cargo test --lib --target x86_64-unknown-linux-gnu parse_selector_older_than_days`

Key result from the log:
- `test system::tests::delete_generations_older_than_days ... ok`
- `test system::tests::parse_selector_older_than_days ... ok`
- each focused run summary: `1 passed; 0 failed`

### 5.6 switch-generation reboot-warning surfacing
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-switch-generation-reboot-warning-host-validation.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-switch-generation-reboot-warning-host-validation.excerpt.txt`

Command:
- `cd snix-redox && PROTO_ROOT=$PWD/upstream PROTOC=$(command -v protoc) cargo test --lib --target x86_64-unknown-linux-gnu switch_generation_`

Key result from the log:
- `test system::tests::switch_generation_missing_generation_errors ... ok`
- `test system::tests::switch_generation_updates_target_etc_files_via_activation ... ok`
- `test system::tests::switch_generation_activates_existing_generation ... ok`
- `test system::tests::switch_generation_reports_reboot_recommended_when_activation_requests_it ... ok`
- focused run summary: `4 passed; 0 failed`

Implementation note:
- `snix-redox/src/system.rs` now routes `switch-generation` through a reporter-backed helper, so the exact path that updates the manifest and current-generation symlink is also the path that emits the reboot recommendation when activation requests it.

### 5.7 focused VM rebuild/rollback validation
Validation log:
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-e2e-rebuild-test.log`
- `openspec/changes/archive/2026-04-13-nix-self-hosting-roadmap/evidence/2026-04-12-e2e-rebuild-test.excerpt.txt`

Command:
- `nix run .#e2e-rebuild-test -- --verbose`

Key result from the log:
- `FUNC_TEST:rebuild-hostname:PASS`
- `FUNC_TEST:rebuild-new-generation:PASS`
- `FUNC_TEST:noop-no-new-gen:PASS`
- `FUNC_TEST:rollback-succeeds:PASS`
- `FUNC_TEST:rollback-hostname-restored:PASS`
- `FUNC_TEST:rollback-new-generation:PASS`
- overall summary: `Passed: 21`, `Failed: 0`

Support files wired into the flake:
- `nix/redox-system/profiles/e2e-rebuild-test.nix`
- `nix/redox-system/test-scripts/21-e2e-rebuild.ion`
- `nix/flake-modules/system.nix`
- `nix/flake-modules/apps.nix`
- `nix/flake-modules/checks.nix`
