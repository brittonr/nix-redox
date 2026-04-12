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
- `openspec/changes/nix-self-hosting-roadmap/evidence/2026-04-10-snix-remote-cache-host-validation.log`
- `openspec/changes/nix-self-hosting-roadmap/evidence/2026-04-10-snix-remote-cache-host-validation.excerpt.txt`

Command:
- `./scripts/validate-snix-redox-host.sh`

Key result from the log:
- `cargo test --lib --target x86_64-unknown-linux-gnu`: `587 passed; 0 failed`
- `cargo test --lib --target x86_64-unknown-linux-gnu: PASS`
- `cargo check --bins --target x86_64-unknown-linux-gnu: PASS`

This log records the host-side validation command after regenerating both unit2nix build plans, including explicit PASS markers for `cargo test --lib` and `cargo check --bins`.

### 2.8 VM test: install from remote cache over HTTP
Validation log:
- `openspec/changes/nix-self-hosting-roadmap/evidence/2026-04-10-network-install-test.log`

Command:
- `nix run .#network-install-test -- --verbose`

Task-specific expected URL/port:
- `http://10.0.2.2:8080`

Key result from the log:
- `FUNC_TEST:net-install-ripgrep:PASS`
- `FUNC_TEST:net-ripgrep-runs:PASS`
- overall summary: `Total: 10 | Pass: 10 | Fail: 0 | Skip: 0`

The HTTP server section of the same log shows the guest fetched the remote cache index plus the corresponding `.narinfo` and `.nar.zst` artifacts over port 8080.

## 5. Generation management follow-up

### 5.2 switch-generation host validation
Validation log:
- `openspec/changes/nix-self-hosting-roadmap/evidence/2026-04-12-switch-generation-host-validation.log`
- `openspec/changes/nix-self-hosting-roadmap/evidence/2026-04-12-switch-generation-host-validation.excerpt.txt`

Command:
- `cd snix-redox && PROTO_ROOT=$PWD/upstream PROTOC=$(command -v protoc) cargo test --lib --target x86_64-unknown-linux-gnu switch_generation_`

Key result from the log:
- `test system::tests::switch_generation_missing_generation_errors ... ok`
- `test system::tests::switch_generation_updates_target_etc_files_via_activation ... ok`
- `test system::tests::switch_generation_activates_existing_generation ... ok`
- overall summary: `3 passed; 0 failed`
