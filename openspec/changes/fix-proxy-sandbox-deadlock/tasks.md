## 1. Restore worker-backed proxy forwarding

- [x] 1.1 Extend `proxy_namespace_test` with a focused reproducer that exercises repeated worker-backed proxy forwarding.
- [x] 1.2 Move real redoxfs and `/dev/*` forwarding off the proxy event-loop thread and onto a dedicated worker thread.
- [x] 1.3 Keep negative coverage for unauthorized paths so allow-list enforcement still returns `EACCES`.

## 2. Re-enable proxy mode with explicit fallback

- [x] 2.1 Re-enable the build proxy path in `snix-redox/src/local_build.rs` as the default sandbox path.
- [x] 2.2 Keep explicit warning + scheme-only fallback behavior when proxy setup fails.
- [x] 2.3 Update proxy diagnostics so logs identify active proxy mode plus forwarded/denied path activity.

## 3. Rebaseline validation and docs

- [x] 3.1 Keep the focused deadlock regression in `proxy_namespace_test` / sandbox-focused coverage.
- [x] 3.2 Re-run `snix-sandbox-test` with proxy mode active and capture durable evidence (`evidence/2026-04-16-snix-sandbox-test.excerpt.txt`, capture dir `/var/tmp/redox-self-hosting-captures/20260416T154023-snix-sandbox-test/`).
- [ ] 3.3 Re-run at least one self-hosting validation pass with proxy mode active (use the current proof wrapper, keep timeout at least 4800s, and preserve heartbeat/capture artifacts).
- [x] 3.4 Update OpenSpec evidence and repo proof docs to reflect the current sandbox pass.
