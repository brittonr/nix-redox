## Context

Redox does not ship a boring system CA store today. snix works around that in multiple places: some code sets `SSL_CERT_FILE`, some upstream reqwest paths panic when trust roots are absent, and self-built binaries can diverge from packaged ones if they miss the same patch or initialization path. The result is fragile remote behavior and confusing differences between local-only commands and TLS-dependent commands.

## Goals / Non-Goals

**Goals:**
- Provide one deterministic CA discovery helper for snix and its upstream HTTP stack.
- Ensure TLS-dependent commands return clear non-panic errors when no bundle exists.
- Make packaged and self-built snix binaries behave the same with respect to CA discovery.

**Non-Goals:**
- Ship a full Redox certificate management subsystem in this change.
- Accept insecure TLS by default.
- Rewrite every HTTP client library used by snix.

## Decisions

### 1. Centralize trust-root discovery in one helper

**Choice:** Introduce a single helper that resolves CA bundle paths in a fixed order and exposes either a usable bundle path or an explicit "no CA bundle available" state.

**Rationale:** Today the logic is scattered. Centralization prevents packaged and self-built binaries from diverging again.

**Alternative considered:** Keep per-call-site `SSL_CERT_FILE` setup. Rejected because that already produced inconsistent behavior.

### 2. Treat missing CA trust as an explicit unsupported state, not an implicit panic workaround

**Choice:** TLS-requiring commands will return a clear error explaining that no CA bundle is available and which path(s) were checked.

**Rationale:** The current `/dev/null` and panic-avoidance behavior is hard to reason about and easy to regress.

**Alternative considered:** Disable certificate verification or silently accept insecure connections. Rejected for obvious trust reasons.

### 3. Validate both packaged and self-built snix

**Choice:** The focused test will exercise the packaged binary and a self-built or source-bundle-built binary against the same HTTPS fixture.

**Rationale:** This exact divergence already bit the project. The test must cover both delivery paths.

**Alternative considered:** Validate only the installed packaged binary. Rejected because it misses the self-hosted path.

## Risks / Trade-offs

- **Different HTTP clients honor trust roots differently** → Normalize around one helper and verify each client path that remains in use.
- **No CA bundle on some images** → Keep local-only functionality working and report precise TLS errors instead of panicking.
- **Upstream snix code may still assume native certs** → Carry a shared Redox-specific patch path until upstream accepts a cleaner hook.

## Migration Plan

1. Add the central discovery helper and switch snix bootstrap to it.
2. Move all TLS client creation onto the same explicit missing-CA behavior.
3. Update source bundle/self-build paths to use the same logic.
4. Add focused HTTPS validation and capture passing evidence.

## Open Questions

- Whether the helper should prefer configuration, environment, or fixed well-known guest paths first.
- Which remaining HTTP paths still need a local patch versus a library-level configuration hook.
