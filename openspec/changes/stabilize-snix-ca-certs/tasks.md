## 1. Centralize CA bundle discovery

- [ ] 1.1 Add a single helper that resolves CA bundle paths in a deterministic order and surfaces either a usable path or an explicit missing-CA state.
- [ ] 1.2 Replace scattered `SSL_CERT_FILE` setup with calls to the shared helper.
- [ ] 1.3 Document the supported CA bundle locations and override behavior.

## 2. Unify TLS client behavior

- [ ] 2.1 Update reqwest/minreq/ureq call sites so TLS-dependent commands use the same trust-root initialization path.
- [ ] 2.2 Convert missing-CA panics into clear user-facing errors that preserve local-only commands.
- [ ] 2.3 Ensure the source-bundle / self-built snix path applies the same behavior.

## 3. Add focused validation

- [ ] 3.1 Add an HTTPS-focused test fixture for remote cache or channel-style access.
- [ ] 3.2 Validate the installed packaged snix binary against that fixture.
- [ ] 3.3 Validate the self-built snix binary against the same fixture and capture durable evidence.

## 4. Update evidence and follow-on docs

- [ ] 4.1 Record the final success and failure modes for images with and without a CA bundle.
- [ ] 4.2 Update remote-cache/channel docs to reference the unified TLS behavior.
- [ ] 4.3 Note any remaining upstream hooks or Redox-specific patches that still block full cleanup.
