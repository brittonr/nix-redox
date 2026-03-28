## 1. Flake Integration

- [x] 1.1 Add `lib.redoxSystem` to flake.nix top-level outputs (via `flake` attrset)
- [x] 1.2 Add `redoxConfigurations` to flake.nix top-level outputs exposing named system configs
- [x] 1.3 Create `nix/flake-module.nix` defining `flake.redoxConfigurations` option for downstream flakes
- [x] 1.4 Add `flakeModules.default` to flake.nix outputs pointing to the flake module
- [x] 1.5 Create `templates/default/flake.nix` with minimal Redox system declaration
- [x] 1.6 Create `templates/default/configuration.nix` with documented profile options
- [x] 1.7 Add `templates.default` to flake.nix outputs

## 2. Standalone Etc Derivation

- [x] 2.1 Extract etc derivation builder from `generated-files.nix` — build a standalone `$out/etc/` store path from `allGeneratedFiles`
- [x] 2.2 Wire the etc derivation into the build module outputs alongside rootTree

## 3. Activatable Toplevel

- [x] 3.1 Generate an `activate` script in `manifest.nix` that performs: update /etc/static, run activation.d scripts, update /run/current-system link, create GC root
- [x] 3.2 Embed the activate script and etc derivation into the toplevel derivation at `$out/activate` and `$out/etc/`
- [x] 3.3 Add `/run/current-system` and `/nix/var/nix/gcroots/current-system` symlink creation to the activate script

## 4. State Version

- [x] 4.1 Add `stateVersion` option (type `t.int`, default 1) to `/system` module
- [x] 4.2 Wire `stateVersion` into `config.nix` so build logic can read it
- [x] 4.3 Include `stateVersion` in the system manifest JSON

## 5. Options Documentation

- [x] 5.1 Create `nix/pkgs/host/options-doc.nix` — a Nix expression that walks the adios module tree and extracts option metadata (path, type name, default, description)
- [x] 5.2 Add `packages.optionsJSON` to the flake (builds the JSON file)
- [x] 5.3 Add `packages.optionsMarkdown` to the flake (renders JSON to Markdown)

## 6. Verification

- [x] 6.1 Verify `nix eval .#lib.redoxSystem` resolves without error
- [x] 6.2 Verify `nix eval .#redoxConfigurations.default.diskImage` matches `nix eval .#redox-default`
- [x] 6.3 Verify `nix build .#optionsJSON` produces valid JSON with entries for all modules
- [x] 6.4 Verify toplevel contains activate script, etc/, and expected symlinks
