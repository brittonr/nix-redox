## Context

snix on Redox can evaluate Nix expressions, build derivations through a sandboxed local builder, and manage a binary cache of pre-built packages. The DSO panic-abort regression is fixed, and the self-hosting test suite runs end-to-end. The sandbox was rolled back from per-path proxy to scheme-only (commit `70b70d74`) due to a kernel deadlock.

Before any of the expansion work below can proceed, the stabilization baseline from `stabilize-self-hosting-baseline` must be complete. That change re-validates the current build pipeline after the sandbox rollback, fixes flake option parity and GitLab forge URLs, and records the current pass/fail set.

## Execution order

1. **Stabilize** (`stabilize-self-hosting-baseline`): fresh test run, classify failures, fix flake/forge bugs, record baseline.
2. **Close gaps** (`fix-snix-build-gaps`): fix remaining correctness failures found during stabilization.
3. **VM-validate remaining gaps** (section 1 below): run test suite with stabilized snix, fix what breaks.
4. **Remote cache** (section 2): HTTP transport for `snix install` and `snix system rebuild`.
5. **Store scheme** (section 3): `stored` daemon with lazy NAR extraction.
6. **Rebuild flow** (section 4): full `snix system rebuild` end-to-end.
7. **Generation management** (section 5): list, switch, rollback, delete.
8. **E2E validation** (section 6): rebuild cycle tests in self-hosting-test profile.

Hardware bring-up (NIC drivers, ACPI, bare metal) is out of scope and should not interleave with self-hosting stabilization.

Existing code that needs VM validation: `fetchers.rs` (fetchGit + forge tarball), `flake.rs` (installable parse/lock/eval/build), `rebuild.rs` (source-based path), `local_build.rs` (sandbox permissions), and the test bundles in `nix/pkgs/infrastructure/`.

Existing code that needs completion: `cache_source.rs` (HTTP transport stubbed, no actual reqwest/minreq), `stored/` (scheme daemon scaffolded, lazy extraction partially wired), `rebuild.rs` (remote cache integration missing), `system.rs` (generation list/switch/delete commands missing).

## Goals / Non-Goals

**Goals:**
- Validate all 4-gaps code on a real Redox guest and fix whatever breaks
- HTTP binary cache client so snix can pull packages from a network server
- Store scheme daemon running in production (lazy NAR extraction on access)
- `snix system rebuild` working end-to-end: eval config → resolve from cache → build missing → activate → create generation
- Generation management: list, switch, delete, rollback

**Non-Goals:**
- Upstream snix/Nix protocol compatibility (nix-serve, cache.nixos.org) — we use our own packages.json format
- Multi-user daemon mode — snix runs as root, single-user
- Garbage collection of the store itself (separate from generation GC) — store paths accumulate for now
- Signing/verification of cache contents — trust-on-first-use model for now
- Flake registry or channel subscriptions — manual cache URLs only

## Decisions

### 1. HTTP client: minreq (not reqwest)

reqwest pulls in tokio, hyper, h2, ring — massive dependency tree that would need cross-compilation and vendoring for Redox. minreq is ~1000 lines, pure Rust, blocking I/O, supports HTTP/1.1 with optional TLS. snix already uses blocking I/O everywhere. minreq's `https` feature uses rustls which we already vendor for other packages.

Alternative considered: raw TCP + hand-rolled HTTP/1.1. Too fragile for chunked transfer encoding, redirects, timeouts. minreq handles all of this.

### 2. VM validation as a gated phase, not continuous

The 4-gaps code compiles and passes host-side unit tests. Rather than set up a VM test loop that runs on every change, we validate once after the panic-abort fix lands, file bugs for whatever breaks, and fix them in-batch. The self-hosting-test profile already has the test harness infrastructure — we just need to run it and iterate.

Rationale: VM boot + test takes 5-15 minutes. Running it per-commit during active development wastes cycles. Run it at phase boundaries.

### 3. stored runs as a separate binary, not inside snix

`stored` registers the `store:` scheme and blocks on the event loop. snix is a CLI tool that exits after each invocation. Combining them would require snix to fork a background daemon on first use, which is fragile on Redox (fork + scheme registration has known issues). A separate binary started by init is the standard Redox pattern (like `smolnetd`, `ptyd`, `ipcd`).

Alternative considered: snix with `--daemon` subcommand. Rejected because init service management expects a dedicated binary path, and combining CLI + daemon in one binary complicates signal handling and error reporting.

### 4. Generation storage: numbered directories under /etc/redox-system/generations/

Each generation is a directory containing `manifest.json`, a symlink `system` pointing to the profile store path, and a `metadata.json` with timestamp and description. The generation records live under `/etc/redox-system/generations/N`, while the current-generation link remains `/nix/system/current` → `/etc/redox-system/generations/N`. This mirrors NixOS's `/nix/var/nix/profiles/system-N-link` pattern but simplified for Redox's single-user model.

Alternative considered: storing generations as store paths themselves. Too complex for the initial implementation — manifests reference other store paths, creating a graph that needs GC roots. Flat directories with metadata files are simpler to list, switch, and delete.

### 5. Rebuild evaluates configuration.nix → merges with manifest → activates

The rebuild flow doesn't do a full NixOS-style evaluation that produces a system derivation. Instead, it evaluates a simple attrset from configuration.nix, merges declarative settings (hostname, packages, networking, users) with the current manifest, resolves package names to store paths from the cache, and activates. This is already implemented in `rebuild.rs` — the work here is wiring in remote cache resolution and source-build fallback.

Rationale: Full NixOS-style system derivations require evaluating all of nixpkgs, which needs thousands of builtins and a complete Nix evaluator. The attrset-merge approach works now and covers the real use cases (add/remove packages, change config, rebuild from source).

## Risks / Trade-offs

**[VM validation uncovers deep bugs]** → The 4-gaps code may hit kernel bugs, sandbox gaps, or relibc issues that weren't visible in unit tests. Mitigation: time-box validation to 2-3 sessions. File openspecs for anything that needs kernel/relibc changes and work around it.

**[minreq doesn't work on Redox]** → relibc's DNS resolution or TCP connect may have issues. Mitigation: test HTTP client early in isolation (simple fetch of packages.json). Fall back to raw TCP if minreq's abstractions hit relibc gaps.

**[stored deadlocks under initnsmgr]** → The stored daemon does file I/O to extract NARs. If it routes through initnsmgr while initnsmgr is forwarding a request to it, circular deadlock. Mitigation: use the pre-opened root fd pattern (documented in AGENTS.md) for all real file I/O. The scheme module already scaffolds this.

**[Generation switch breaks boot]** → Switching to a generation with incompatible boot components could leave the system unbootable. Mitigation: generation switch only changes the profile symlink and etc files — boot components (kernel, initfs) require an explicit reboot. If the new generation's boot components don't match the running kernel, warn but don't force reboot.

**[Remote cache adds network dependency to rebuild]** → If the cache server is unreachable, rebuild fails. Mitigation: local cache remains the default. Remote is opt-in via `--cache-url`. Source-build fallback (`--source`) works fully offline.

## References

These are background references for the longer-term bootstrap and supply-chain direction around self-hosting:

- [Bootstrappable Builds](https://www.bootstrappable.org/) — project hub for reducing bootstrap binaries and documenting practical bootstrap paths.
- [GNU Guix: "The Full-Source Bootstrap: Building from source all the way down"](https://guix.gnu.org/en/blog/2023/the-full-source-bootstrap-building-from-source-all-the-way-down/) — detailed write-up of Guix reaching a tiny audited bootstrap root for a full distro graph.
- [StageX](https://codeberg.org/stagex/stagex) — a full-source-bootstrapped, reproducible distribution/toolchain effort with design goals adjacent to later Redox self-hosting work.
