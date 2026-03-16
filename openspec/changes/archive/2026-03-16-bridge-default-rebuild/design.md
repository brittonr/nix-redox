## Context

Two rebuild paths exist in snix-redox:

**Local** (`rebuild.rs`): Evaluates `configuration.nix` as a simple attrset via `snix eval`, resolves package names against `/nix/cache/packages.json`, merges into the running manifest, activates. Works for config-only changes (hostname, timezone, DNS, users). Package resolution is fragile — the JSON index is a flat name→store-path map that doesn't capture dependencies or handle version conflicts.

**Bridge** (`bridge.rs`): Sends the parsed `RebuildConfig` JSON to the host via virtio-fs (`/scheme/shared/requests/`). The host's `build-bridge` daemon runs real `nix build`, produces a complete manifest with proper store paths and dependencies, exports packages to the shared cache. Guest polls for response, installs packages, activates. This produces correct results identical to a fresh `nix build .#diskImage`.

The bridge path requires: (1) VM launched with `--shared` (virtio-fs mount at `/scheme/shared`), and (2) the `build-bridge` daemon running on the host. Both are true when using `nix run .#run-redox-shared` + `nix run .#build-bridge`.

The guest can detect bridge availability by checking if `/scheme/shared` exists and contains the expected directory structure (requests/, responses/, cache/).

## Goals / Non-Goals

**Goals:**
- Auto-route `snix system rebuild` to bridge when package changes are detected and bridge is available
- Clear error when package changes are requested without bridge
- Keep config-only local rebuilds fast and working (no bridge round-trip needed for hostname changes)
- Maintain `--bridge` and add `--local` as explicit overrides
- Update the rebuild-generations-test to work with the new routing

**Non-Goals:**
- Changing the bridge protocol (request/response format stays the same)
- Making the local path handle package changes correctly (that's the long-term on-guest Nix eval goal)
- Auto-starting the build-bridge daemon from the guest
- Changes to how the VM is launched or virtio-fs is configured

## Decisions

### 1. Route based on config content, not just flag presence

The auto-router parses the config first (via `evaluate_config()`), then checks if `packages` is `Some` and non-empty. If packages changed, it needs the bridge. If only config fields changed, local is fine.

*Alternative: Always use bridge when available.* Rejected — config-only changes complete in <1s locally vs 10-30s via bridge (host Nix eval + export + install). The speed difference matters for iteration.

### 2. Detect bridge via `/scheme/shared/requests` directory

Check `Path::new("/scheme/shared/requests").is_dir()`. This is more reliable than just checking `/scheme/shared` (which could be a stale mount point). The requests directory is created by the build-bridge daemon.

*Alternative: Check for a sentinel file.* Rejected — the directory structure is sufficient and doesn't require the daemon to write extra files.

### 3. Error, don't silently fall back

When packages changed and no bridge is available, emit a clear error with instructions:

```
error: package changes require the build bridge

  Your configuration.nix modifies `packages`, which requires the host
  to build the new package set. Start the VM with shared filesystem:

    nix run .#run-redox-shared     (in one terminal)
    nix run .#build-bridge         (in another terminal)

  Then re-run: snix system rebuild

  To apply config-only changes without the bridge: remove the
  `packages` line from configuration.nix and re-run.

  To force local resolution (may produce incomplete results):
    snix system rebuild --local
```

*Alternative: Silently fall back to local.* Rejected — we just spent a whole change fixing bugs in the local package resolution path. It produces wrong results (wipes packages) and users deserve to know.

### 4. `--local` flag for testing and escape hatch

Keep the local package resolution path accessible via `--local` for testing and for users who understand the tradeoffs. The rebuild-generations-test Phase 8 will use `--local` since it tests the local resolution path specifically.

### 5. No changes to the bridge protocol or host-side daemon

The build-bridge daemon, request/response format, and virtio-fs setup all stay the same. This change is purely guest-side routing logic.

## Risks / Trade-offs

- **[Bridge detection false positive]** If `/scheme/shared/requests` exists but the daemon isn't running, the rebuild will hang waiting for a response. → Mitigation: the existing timeout (default 300s) handles this. Could add a quick liveness check (write a ping request, wait 5s) but that's scope creep for now.
- **[Test profile changes]** The rebuild-generations-test Phase 8 uses the local path for package addition. Needs `--local` flag or the test will fail when bridge isn't available. → Mitigation: task explicitly covers updating the test.
- **[Config-only detection edge case]** A config that sets `packages = []` (empty list) is ambiguous — did the user mean "remove all packages" or "no change"? → Decision: treat empty list same as absent (no package change). To clear packages, user must use the bridge.
