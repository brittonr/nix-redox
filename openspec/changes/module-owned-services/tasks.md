## 1. Shared service type

- [x] 1.1 Create `nix/redox-system/lib/service-type.nix` that takes `{ t }` and returns the serviceType struct (description, command, type, args, wantedBy, enable, after, environment, priority)
- [x] 1.2 Update `services.nix` to import the shared type instead of defining it inline
- [x] 1.3 Verify `nix run .#test-quick` passes (module system + eval tests)

## 2. Networking module services

- [x] 2.1 Add `services` option to `/networking` with `defaultFunc` that computes smolnetd, dhcpd, netcfg-auto, netcfg-static, remote-shell based on enable/mode/remoteShellEnable
- [x] 2.2 Add `inputs` for `/networking` if cross-module data is needed (check firstIface — may need interface data from own options)
- [x] 2.3 Verify `nix run .#test-quick` passes

## 3. Graphics module services

- [x] 3.1 Add `inputs` to `/graphics`: `/hardware` (for audioEnable) and `/pkgs` (for orbutils check)
- [x] 3.2 Add `services` option with `defaultFunc` that computes orbital (with VT env, login command) and audiod (conditional on audioEnable)
- [x] 3.3 Verify `nix run .#test-quick` passes

## 4. Snix module services

- [x] 4.1 Add `services` option to `/snix` with `defaultFunc` that computes stored and profiled based on their enable flags and path options
- [x] 4.2 Verify `nix run .#test-quick` passes

## 5. Iroh module services

- [x] 5.1 Add `services` option to `/iroh` with `defaultFunc` that computes irohd based on enable flag, with after `[ "smolnetd" ]`
- [x] 5.2 Verify `nix run .#test-quick` passes

## 6. Services module: core + typed services

- [x] 6.1 Add `/pkgs` input to `/services` module
- [x] 6.2 Update the `services` option `default` (or add `defaultFunc`) to generate core services (ipcd priority 10, ptyd priority 11) and typed services (ssh, httpd, getty, exampled, sudod) from the typed service options
- [x] 6.3 Resolve getty "auto" within the defaultFunc using the `/pkgs` input to check userutilsInstalled
- [x] 6.4 Ensure profile-declared services in the `services` attrset merge correctly (profile values override generated defaults)
- [x] 6.5 Verify `nix run .#test-quick` passes

## 7. Build module: collect from inputs

- [x] 7.1 Replace the ~280 lines of per-module service blocks in `init-scripts.nix` with input collection: merge `inputs.services._generatedServices // inputs.networking.services // inputs.graphics.services // inputs.snix.services // inputs.iroh.services // inputs.services.services`
- [x] 7.2 Remove service-block-only `cfg.*` fields from `config.nix`: `gettyEnabled`, `gettyOpts`, `exampledEnabled`, `exampledOpts`, `firstIface`, `graphicsLoginCommand`, `virtualTerminal` (keep fields used by generated-files.nix, assertions.nix, or initfs scripts)
- [x] 7.3 Verify `nix run .#test-quick` passes

## 8. Full validation

- [ ] 8.1 Run `nix run .#test-host` — all eval, artifact, type, and lib tests pass
- [ ] 8.2 Run `nix run .#functional-test` — VM boots, services start correctly
- [ ] 8.3 Verify service init scripts in rootTree match previous output (diff check: same service names, same numbering, same content)
- [ ] 8.4 Verify manifest.json `services.declared` contains all expected services
