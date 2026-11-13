# Snix Redox port

`snix-redox` is the in-tree Redox integration around upstream Snix crates. It
provides the guest `snix` command; it is not the upstream C++ `nix` executable or
an unmodified build of the upstream Snix CLI. The port, its packaging, and the
Redox OS integration remain in this repository.

## Upstream baseline and assembly

The local package is version **0.4.0**. Its upstream Snix source is pinned to
`34604636d7e3adbad6f7f909c98bb493f26855f9` from
`https://git.snix.dev/snix/snix.git`. These are separate version identities.

The assembly entry points are:

| Entry point | Responsibility |
|---|---|
| [`snix-redox/Cargo.toml`](../snix-redox/Cargo.toml) | Local CLI/library, upstream workspace members, feature selection, and shared dependency overrides |
| [`snix-upstream-source.nix`](../nix/pkgs/infrastructure/snix-upstream-source.nix) | Fetch the upstream pin, extract the required crates, and transform their manifests, sources, and build scripts |
| [`packages.nix`](../nix/flake-modules/packages.nix) | Compose the source and construct the Redox cross-package using the unit2nix build plan |
| [`checks.nix`](../nix/flake-modules/checks.nix) | Host-side Rust validation using the combined source |
| [`snix-source-bundle.nix`](../nix/pkgs/infrastructure/snix-source-bundle.nix) | Assemble the separate guest-native source bundle, vendor dependencies, and apply native-only accommodations |
| [`build-snix.sh`](../nix/pkgs/infrastructure/build-snix.sh) | Run the guest-native offline Cargo build through a Nix derivation |

Most upstream transformations are in `snix-upstream-source.nix`, not standalone
files under `snix-redox/patches/`. The patch directory alone is not a complete
inventory. For local development, `snix-redox/upstream` is a symlink to the
assembled upstream output; Nix builds populate that tree in the combined source.

## Changes to upstream Snix crates

The port reuses upstream Nix evaluation, derivation builtins, store-path/hash/NAR
formats, and derivation-to-build-request conversion. It does not replace the Nix
parser, compiler, or evaluator with a Redox-specific language implementation.

The upstream assembly applies these adaptations:

- **System recognition:** add `redox` to the recognized operating-system
  coordinate when converting LLVM triples to Nix system names.
- **Public integration hooks:** expose `derivation_into_build_request`, the
  `fetchurl` module, and its derivation conversion/error types so the local
  executor can use them.
- **Backend and dependency selection:** remove unconditional FUSE dependencies;
  gate Linux bubblewrap/OCI support; disable default cloud/FUSE/reflection
  features; exclude object-store-backed services on Redox; and remove unused
  normal-dependency edges to mimalloc.
- **Async/procedural-macro accommodations:** avoid Tokio's macros feature on
  Redox and replace selected `join!`/`try_join!` calls with ordinary future
  functions. The Redox CLI signal branch awaits Ctrl+C rather than using the
  upstream Ctrl+C/SIGTERM selection macro.
- **HTTP initialization:** make upstream glue's HTTP client optional so client
  construction failure does not prevent offline evaluation/building. This is
  not a TLS-verification bypass; unavailable-client call sites can still fail.
- **Protobuf generation:** generate descriptor sets on the host and replace the
  three upstream protobuf build scripts with versions that can consume those
  descriptors without a guest `protoc`.

The workspace selects rustls with the `ring` provider instead of `aws-lc-rs` for
relibc compatibility. The local cache/download paths also use synchronous
`minreq` and `ureq`, plus Rust compression implementations. See the dependency
configuration in [`Cargo.toml`](../snix-redox/Cargo.toml) and the HTTP-client
transformation in
[`patch-snix-fetcher-no-tls-panic.py`](../nix/pkgs/userspace/patches/patch-snix-fetcher-no-tls-panic.py).

## Local Redox functionality

These features are implemented in the local crate rather than supplied by the
upstream Snix CLI:

| Area | Local implementation and boundary |
|---|---|
| Evaluation/fetch integration | [`eval.rs`](../snix-redox/src/eval.rs) connects upstream evaluation to local store metadata, preserves source-file locations, and supplies a Git-CLI-based `fetchGit`. |
| Native build execution | [`local_build.rs`](../snix-redox/src/local_build.rs) schedules dependency builds, obtains an upstream `BuildRequest`, executes builders, handles builtin fetchers, and registers outputs. Evaluation's upstream `DummyBuildService` is not this executor. |
| Store and package management | [`pathinfo.rs`](../snix-redox/src/pathinfo.rs), [`store.rs`](../snix-redox/src/store.rs), and [`install.rs`](../snix-redox/src/install.rs) implement local JSON path metadata, closures/GC roots, cache-backed installation, and profiles rather than using the upstream C++ Nix store database. |
| Flakes and channels | [`flake.rs`](../snix-redox/src/flake.rs) resolves supported locked inputs and evaluates a generated expression; [`channel.rs`](../snix-redox/src/channel.rs) manages manifest/package-index URLs. This is not full upstream Nix flake support: lock writing, registries, `--override-input`, and recursive flake-output evaluation are unsupported. |
| System management | [`rebuild.rs`](../snix-redox/src/rebuild.rs), [`system.rs`](../snix-redox/src/system.rs), and [`activate.rs`](../snix-redox/src/activate.rs) implement configuration/manifest handling, native `systemSource` routing, generations, activation, boot selection, and rollback. This is our Redox management layer, not NixOS's module/activation implementation. |
| Optional host builds | [`bridge.rs`](../snix-redox/src/bridge.rs) and [`bridge_build.rs`](../snix-redox/src/bridge_build.rs) exchange build requests/results through a shared filesystem. This route is distinct from guest-native building. |
| Redox schemes and filesystem I/O | [`stored/`](../snix-redox/src/stored/), [`profiled/`](../snix-redox/src/profiled/), and [`file_io_worker.rs`](../snix-redox/src/file_io_worker.rs) provide lazy store access, profile views, and off-handler filesystem I/O to avoid scheme-handler deadlocks. |

[`sandbox.rs`](../snix-redox/src/sandbox.rs) and
[`build_proxy/`](../snix-redox/src/build_proxy/) implement Redox scheme namespaces
and the build filesystem proxy. The proxy permits read access to the entire
store and several system/source paths, not only declared derivation inputs. If
proxy setup fails, the executor falls back to scheme-level isolation with the
real filesystem visible. Do not describe this as input-only filesystem isolation
or an unconditional filesystem security boundary.

## Cross-build versus guest-native self-build

The normal package and host tests use the base combined source. The shared
workspace overrides `tonic`, `futures-macro`, and `tracing-attributes`:

- The tonic copy removes Tokio-macro feature edges.
- The futures macro replacement supports the two-argument join/try-join forms;
  unsupported selection macros produce compile errors.
- The tracing attribute replacement passes the annotated item through without
  adding the upstream instrumentation.

The guest source bundle adds further transformations to its copied manifest and
source tree. These are **not automatically part of the normal cross-package**:

- Additional local dependency/procedural-macro replacements.
- Host-generated protobuf Rust modules copied into `OUT_DIR`, avoiding guest
  protobuf code generation as well as guest `protoc` execution.
- Default-config handling for empty-query redb service URLs, bypassing native
  Serde deserialization in that narrow case.
- Offline vendoring, one Cargo job, the Redox linker, and a serial
  curve25519-dalek backend. The builder also sets explicit Rayon and rustc flags
  for current Redox compiler/runtime limitations.

### Native dependency replacements are not all semantics-preserving

The native bundle includes compatibility shims, not merely build-system fixes.
In particular, its
[`serde_derive` replacement](../snix-redox/vendor-patches/serde_derive-1.0.228/src/lib.rs)
emits serialization as unit and deserialization that always returns an error.
The empty-query redb workaround does not restore general Serde functionality.

For the source bundle used by the `e0f0102` proof, offline Cargo metadata
resolution selected the local `serde_derive 1.0.228`, `prost-derive 0.13.5`, and
`thiserror-impl 1.0.69`/`2.0.18` replacements, among others. This distinguishes the
native bundle from the base workspace's dependency graph.

Conversely, local patch candidates for `clap_derive 4.6.0`,
`pin-project-internal 1.1.11`, `tokio-macros 2.6.1`, and
`serde_with_macros 3.18.0` were reported unused by that resolution. For example,
the selected Clap derive was the registry's `4.6.1`, not the local shim whose
parsing implementation panics. A file under `vendor-patches/` or an injected
`[patch.crates-io]` entry is not sufficient evidence that Cargo selects it.
Recheck the resolved graph when changing the lockfile or dependency constraints.

## What the self-hosting proofs establish

The [proof artifact contract](self-hosting/proof-artifacts.md) and
[latest-success index](self-hosting/latest-success.md) record the actual VM runs.
Keep these claims separate:

- **Snix self-build:** the seed Snix builds the bundled Snix source inside Redox.
  The produced binary is then checked with `--version` and
  `eval --expr "1 + 1"`. It is not proven feature-equivalent to the cross-built
  binary, and the native dependency shims prevent assuming that equivalence.
- **Source/system rebuild tests:** subsequent rebuild checks use the seed
  `/bin/snix`, not the newly self-built Snix. See the
  [self-hosting profile](../nix/redox-system/profiles/self-hosting-test.nix) and
  [native system runner](../nix/pkgs/infrastructure/run-native-system-rebuild-test.sh).
- **Native OS graph:** with `systemSource`, Snix evaluates Nix derivations and
  builds the kernel, UEFI bootloader, initfs tools, initfs, configuration, and
  generation inside Redox without the Linux build bridge. The proof boots that
  generation and rolls back to the original generation.
- **Bootstrap boundary:** the seed image, compiler/toolchain, libraries, existing
  userspace packages, and drivers are prepared on the host and reused. The
  three-boot proof also uses host-assisted ESP installation of guest-built EFI
  bytes. It is not an all-packages/toolchain rebuild or a guest-side ESP installer.

A complete package-manager bootstrap claim would additionally require the
newly built Snix to execute real builds, preserve/read store and system metadata,
and perform the next rebuild with the intended dependency semantics. The current
version/evaluation smoke checks do not establish that claim.
