## Why

snix on Redox treats the OS like a generic POSIX box — flat filesystem I/O to `/nix/store/`, symlink farms for profiles, unsandboxed `Command::new()` for builders. The only Redox-specific thing is virtio-fs at `/scheme/shared`. This ignores Redox's core architecture: **everything is a scheme**. Schemes are URL-namespaced userspace daemons, resources are file-descriptor handles to scheme endpoints, and per-process namespace tables control which schemes a process can access. This is Redox's native isolation model — no Linux namespaces, no cgroups, no seccomp needed.

The current approach has concrete problems:
- **Eager extraction**: `snix install` decompresses and extracts the entire NAR to `/nix/store/` upfront, even for packages where the user may only run one binary. A 50 MB ripgrep NAR gets fully extracted even though only `bin/rg` is ever accessed.
- **No build isolation**: `local_build.rs` runs builders via `Command::new()` with `env_clear()` but zero filesystem isolation. A malicious or buggy builder can read/write anywhere the process has access.
- **Symlink farms are fragile**: Profile management creates/deletes symlinks in `/nix/var/snix/profiles/default/bin/`. Adding or removing a package touches N files. A crash mid-operation leaves a broken profile.
- **No composition**: There's no way to present a union view of multiple store paths without materializing symlinks. NixOS on Linux solves this with `buildEnv` — another build step. Redox schemes can do it with a lookup table.

Redox already has working scheme infrastructure — `file:`, `disk:`, `net:`, `display:` are all userspace daemons. The kernel routes `open("/scheme/foo/path")` to the `foo` scheme daemon. This change builds three new scheme daemons that turn snix from a Linux package manager that compiles for Redox into a Redox-native package manager.

## What Changes

- **`stored` — Store scheme daemon**: A userspace daemon that serves `/nix/store/` paths on demand. Opening `store:{hash}-{name}/bin/rg` checks if the path is extracted; if not, it lazily fetches from the binary cache (local or remote), decompresses, and extracts before serving the file descriptor. Already-extracted paths are served directly from the filesystem. The daemon maintains the PathInfoDb and manages the on-disk cache.

- **`profiled` — Profile scheme daemon**: A userspace daemon that presents a union view of installed packages. Opening `profile:default/bin/rg` resolves through a package mapping to the underlying store path — no symlink farm needed. Installing/removing a package updates an in-memory mapping table and persists it to a manifest file. The resolution is atomic — no partial states from interrupted symlink operations.

- **Namespace-restricted builds**: When `local_build.rs` executes a builder, it restricts the child process's scheme namespace to only the schemes the derivation declares as inputs. The builder can access its declared input store paths (via `store:` scheme) and its output directory, but nothing else. This uses Redox's native `setns`/namespace syscalls — the same mechanism the kernel uses to isolate drivers.

- **Fallback compatibility**: All three capabilities are additive. The existing `/nix/store/` filesystem paths continue to work. The scheme daemons are started by init if configured; if they're not running, snix falls back to direct filesystem operations exactly as it does today.

## Capabilities

### New Capabilities
- `store-scheme`: Lazy content-addressed store served via a Redox scheme daemon. Covers on-demand NAR extraction, transparent cache fallback (local → remote), PathInfoDb integration, and concurrent file serving.
- `profile-scheme`: Atomic profile management via a Redox scheme daemon. Covers union directory views, instant package add/remove via mapping table updates, profile generations as manifest snapshots, and multi-profile support.
- `namespace-sandboxing`: Build isolation using Redox's native per-process scheme namespace restrictions. Covers input-only store path visibility, output directory isolation, network access control for FODs, and builder execution under restricted namespaces.

### Modified Capabilities
- `local-build`: Modified to set up namespace restrictions before executing builders. Falls back to current unsandboxed behavior if namespace syscalls are unavailable.
- `install`: Modified to register with `stored` daemon when available, falling back to direct filesystem extraction.
- `profile-management`: Modified to delegate to `profiled` daemon when available, falling back to symlink farm.

## Impact

- **New files**: `snix-redox/src/stored/` — store scheme daemon (main loop, FUSE-like scheme handler, lazy extraction)
- **New files**: `snix-redox/src/profiled/` — profile scheme daemon (mapping table, union directory serving)
- **Modified**: `snix-redox/src/local_build.rs` — namespace setup before builder execution
- **Modified**: `snix-redox/src/install.rs` — optional delegation to stored/profiled daemons
- **Modified**: `snix-redox/src/main.rs` — new `snix stored` and `snix profiled` subcommands for daemon mode
- **New files**: `nix/redox-system/modules/services/stored.nix`, `profiled.nix` — module system integration
- **New files**: `nix/pkgs/system/stored/`, `nix/pkgs/system/profiled/` — package definitions
- **Modified**: `nix/redox-system/profiles/` — profiles can opt into scheme-based package management
- **No breaking changes**: Everything falls back to current behavior when daemons are not running
