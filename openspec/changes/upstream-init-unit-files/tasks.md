## 1. Service rendering (init-scripts.nix)

- [ ] 1.1 Add `renderServiceToml` function that produces TOML `[unit]` + `[service]` content from a service declaration, mapping type → TOML type field (`scheme` → `{ scheme = "name" }`, `daemon` → `"notify"`, `oneshot` → `"oneshot"`, `nowait` → `"oneshot_async"`), environment → `envs`, and after → `requires_weak` with unit filenames
- [ ] 1.2 Update `renderedServices` to use `.service` extension in output keys and call `renderServiceToml` instead of `renderServiceText`
- [ ] 1.3 Filter logd from generated services (init starts it explicitly between SwitchRoot calls)

## 2. Initfs unit files (init-scripts.nix)

- [ ] 2.1 Replace `defaultInitScriptFiles` shell scripts with TOML unit files: generate individual `.service` files for each initfs daemon (nulld, zerod, randd, rtcd, vesad, inputd, fbbootlogd, fbcond, lived, ps2d, hwd, pcid-spawner, redoxfs) with correct `type`, `args`, and `default_dependencies` settings
- [ ] 2.2 Generate `00_runtime.target` with `requires_weak` listing core runtime services and `default_dependencies = false`
- [ ] 2.3 Generate driver/graphics `.target` files grouping related services
- [ ] 2.4 Generate `90_initfs.target` with `requires_weak` including rootfs mount service
- [ ] 2.5 Create `85_generation_select` as a legacy extensionless script (init supports `UnitKind::LegacyScript` for files without extensions)

## 3. Rootfs environment setup

- [ ] 3.1 Create a legacy extensionless rootfs init script (`99_environment`) that sets TERM, HOME, USER, XDG_CONFIG_HOME, PATH, and optionally LD_LIBRARY_PATH/CARGO_HOME for self-hosting profiles
- [ ] 3.2 Ensure getty/stdio setup is handled in the rootfs init script for profiles with userutils

## 4. Initfs assembly (initfs.nix)

- [ ] 4.1 Update initfs.nix to write `.service` and `.target` files with proper extensions to `etc/init.d/` instead of extensionless shell scripts

## 5. Rootfs assembly (root-tree.nix)

- [ ] 5.1 Verify `usr/lib/init.d/` directory is created and populated with rootfs `.service` files from `allInitScripts`

## 6. Validation

- [ ] 6.1 Build disk image and verify boot reaches init switchroot with no "unit not found" errors
- [ ] 6.2 Run functional test suite and confirm all tests pass
- [ ] 6.3 Verify post-boot environment variables (PATH, TERM, HOME) are set correctly
