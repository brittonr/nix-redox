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
- [x] 3.3 Re-run at least one self-hosting validation pass with proxy mode active (use the current proof wrapper, keep timeout at least 4800s, and preserve heartbeat/capture artifacts).
  - 2026-10-28 pass (`93107723`, capture `/var/tmp/redox-self-hosting-captures/20261028T140018-self-hosting-test/`, excerpt `evidence/2026-10-28-self-hosting-test.excerpt.txt`): 82 passed, 0 failed, 2 skipped. `source-rebuild`, `source-rebuild-gen`, `source-rebuild-pkg`, and `source-rebuild-dry` all PASS under `buildfs: proxy mode active`; the 2 skips are the documented `cargo-vendored-dep` / `direct-cc-dep-script` mutable-mapping cases.
  - Rebaseline also exposed and fixed a second proxy deadlock: `BuildFsProxy::start` polled the helper READY file for only 2s (200×10ms) and then called `child.wait()` while the helper was still serving its event loop, so a slow rustlib/vendor pre-scan on the loaded post-compile filesystem hung the parent forever. Commit `6d158245` extends the window to 60s and kills/reaps the helper on timeout.
  - 2026-10-26 attempt (`f07b8efd`, capture `/var/tmp/redox-self-hosting-captures/20261026T102638-self-hosting-test/`) ran under `buildfs: proxy mode active`: 74 passed, 2 failed, 1 skipped, then hit the 14400s cap in `source-rebuild`. Remaining failures are `cargo-vendored-dep` (cargo exit 101) and `snix-compile` (guest self-build `async-trait` errors in upstream `castore`); the proxy-path fixtures pass.
  - 2026-04-16 attempt captured durable artifacts at `/var/tmp/redox-self-hosting-captures/20260416T165825-self-hosting-test/` and `evidence/2026-04-16-self-hosting-test-fail.excerpt.txt`, but the run failed with `cc-dep-build` and `workspace-build` under `buildfs: proxy mode active`; the 2026-10-28 pass above supersedes it.
  - Current classification: `snix-sandbox-test` and `self-hosting-test` share the same self-hosting base profile and source bundles, so the regression currently localizes to the weaker `self-hosting-test` harness/observability around these fixtures rather than an obvious static package mismatch.
- [x] 3.4 Update OpenSpec evidence and repo proof docs to reflect the current sandbox pass.
