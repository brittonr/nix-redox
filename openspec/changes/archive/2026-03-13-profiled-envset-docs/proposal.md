## Why

Three loose ends from the scheme-native and self-hosting work need closure:
the profiled execution test is skipped (broken path assumption), the `--env-set`
cargo workaround masks a real relibc bug that should be investigated, and the
README hasn't been updated since February — missing snix, scheme daemons,
self-hosting, the build bridge, and network cache.

## What Changes

- **Fix profiled execution test**: The `rg-from-profile-works` test in
  `scheme-native-test.nix` checks `/nix/var/snix/profiles/default/bin/rg`
  (filesystem symlinks) but profiled serves data through the `profile:` scheme
  only. Fix: test execution via the known store path, add a separate test for
  scheme-path file reads, and document the scheme-vs-filesystem distinction.

- **Investigate and remove `--env-set` workaround**: The `patch-cargo-env-set.py`
  duplicates every `CARGO_PKG_*` env var as `--env-set` flags because `execvpe()`
  doesn't fully propagate env vars in DSO-linked processes. Investigate the root
  cause (DSO environ initialization order), fix it in relibc if possible, and
  remove the workaround. If the fix isn't tractable, document why the workaround
  is permanent.

- **Update README.md**: Rewrite to reflect the current state — snix (eval, build,
  install, scheme daemons), self-hosting (cargo on Redox, 58 tests), build bridge
  (virtio-fs), network binary cache, flake installables, redox-rebuild CLI, and
  accurate test counts (461 host / 129 functional / 58 self-hosting).

## Capabilities

### New Capabilities
- `profiled-execution`: Fix the skipped test and verify end-to-end binary execution through the profile system when scheme daemons are active.
- `env-propagation-cleanup`: Investigate DSO environ propagation, remove or document the `--env-set` workaround.
- `readme-update`: Comprehensive README rewrite covering all current features.

### Modified Capabilities

## Impact

- `nix/redox-system/profiles/scheme-native-test.nix` — test fix
- `nix/pkgs/userspace/patch-cargo-env-set.py` — potential removal
- `nix/pkgs/userspace/rustc-redox.nix` — remove env-set patch application
- `nix/pkgs/system/patch-relibc-execvpe.py` — potential update
- `README.md` — full rewrite
