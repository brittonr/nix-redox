## 1. Expand Service Type

- [x] 1.1 Add `after` field (`t.listOf t.string`, default `[]`) to `serviceType` in `services.nix` — list of service names that must start before this one
- [x] 1.2 Add `environment` field (`t.attrsOf t.string`, default `{}`) to `serviceType` — per-service environment variables rendered as `export KEY VALUE` lines
- [x] 1.3 Add `priority` field (`t.int`, default `50`) to `serviceType` — explicit numeric override, auto-numbering only applies when priority is default

## 2. Module Service Declarations

- [x] 2.1 In `networking.nix` impl, declare `smolnetd` service (daemon, wantedBy rootfs, after ptyd) when `enable = true`; declare `dhcpd` service (nowait) when mode is dhcp/auto; declare `netcfg-setup` service (oneshot) when mode is static/auto
- [x] 2.2 In `graphics.nix` impl, declare `orbital` service (nowait, environment `{ VT = "3"; }`, after inputd/fbcond) when `enable = true`; declare `audiod` service (nowait) when audioEnable
- [x] 2.3 In `snix.nix` impl, declare `stored` service (nowait, wantedBy rootfs) when stored.enable; declare `profiled` service (nowait, wantedBy rootfs) when profiled.enable
- [x] 2.4 In `services.nix` default initScripts, declare `ptyd` and `ipcd` as daemon services (wantedBy rootfs, no after deps) — these are currently in `00_base` raw script
- [x] 2.5 Declare `getty` service (nowait, wantedBy rootfs, after ptyd, environment `{ XDG_CONFIG_HOME = "/etc"; }`) when userutilsInstalled, in the build config or services module

## 3. Build Module: Service Rendering

- [x] 3.1 In `init-scripts.nix`, implement `topoSortServices` — take the merged `services.services` attrset, build adjacency list from `after` fields, detect cycles (throw on cycle), return sorted list of `{ name, number, service }` with numbers assigned 10-79
- [x] 3.2 Rewrite `renderService` to emit `export` lines from `environment`, then the type-specific command line (`notify`/`nowait`/`scheme`/bare), with a `# description` comment header
- [x] 3.3 Replace the hardcoded `allInitScripts` conditional blocks (networking, graphics, snix, getty) with consumption of the merged+sorted service declarations — the allInitScripts attrset should come from rendered services + raw initScripts
- [x] 3.4 Ensure raw `initScripts` entries with explicit numeric names (00_runtime, 10_logging, 20_graphics, 30_live, 40_drivers, 50_rootfs, 85_generation_select, 90_exit_initfs) are preserved unchanged in the initfs initScriptFiles
- [x] 3.5 Add build assertion: service dependency graph is acyclic and all `after` references exist in the service set

## 4. Manifest Update

- [x] 4.1 Add `services.declared` field to `manifestData` in `manifest.nix` — attrset of `{ name = { type, command, wantedBy, environment, after, description }; }` for each enabled service
- [x] 4.2 Update `Services` struct in `system.rs` to include `declared: BTreeMap<String, ServiceInfo>` with `ServiceInfo { svc_type, command, wanted_by, description }`
- [x] 4.3 Update manifest JSON parser in `system.rs` to deserialize the new `services.declared` field, falling back to empty map for v2 manifests

## 5. Activation Plan: Service Diffs

- [x] 5.1 In `activate.rs`, change service diff logic from comparing `init_scripts` string lists to comparing `declared` service maps — detect added, removed, and changed services (command, type, or environment changed)
- [x] 5.2 Update `ActivationPlan` display to show `+ serviceName (type)` / `- serviceName (type)` / `~ serviceName (description of change)` instead of raw init script names
- [x] 5.3 Add unit tests for service-level diffing: service added, removed, type changed, environment changed, command changed

## 6. Build Checks

- [x] 6.1 Add check in `checks.nix` that validates the service dependency graph (all `after` targets exist, no cycles) — replicating the Nix-side topo sort validation
- [x] 6.2 Add check that no auto-numbered service collides with a raw initScript number

## 7. Profile Migration and Testing

- [x] 7.1 Update `functional-test.nix` to use the new service declarations (verify it still doesn't include userutils-dependent services)
- [x] 7.2 Update `development.nix` and `graphical.nix` — remove any explicit initScripts that are now covered by module declarations
- [x] 7.3 Verify all test profiles build (`nix build .#checks.x86_64-linux.functional-test-checks`) and produce correct init script content
- [x] 7.4 Run functional-test VM to verify boot sequence is unchanged — all FUNC_TEST assertions pass
