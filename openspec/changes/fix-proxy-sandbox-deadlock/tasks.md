## 1. Reproduce and pin down the deadlock

- [ ] 1.1 Add a focused reproducer that owns a scheme socket and then exercises forwarded `SYS_OPENAT(root_fd, ...)` on an allowed path.
- [ ] 1.2 Capture the failing trace and document the exact kernel block point in the change evidence.
- [ ] 1.3 Define the runtime capability check snix will use before enabling proxy mode.

## 2. Implement the kernel-side safety fix

- [ ] 2.1 Patch the kernel so proxy forwarding through a pre-opened real filesystem fd no longer deadlocks while a scheme socket is owned.
- [ ] 2.2 Add negative coverage proving unrelated unauthorized paths still fail.
- [ ] 2.3 Verify the focused reproducer passes on the patched kernel.

## 3. Re-enable proxy mode in snix

- [ ] 3.1 Re-enable the build proxy path in `snix-redox/src/local_build.rs` behind the runtime capability check.
- [ ] 3.2 Keep explicit warning + scheme-only fallback behavior for unsupported kernels.
- [ ] 3.3 Update proxy lifecycle and diagnostic logging so failures identify whether proxy mode or fallback mode was used.

## 4. Rebaseline validation and docs

- [ ] 4.1 Extend `proxy_namespace_test` / sandbox-focused tests to cover the former deadlock path.
- [ ] 4.2 Re-run `snix-sandbox-test` and at least one self-hosting validation pass with proxy mode active.
- [ ] 4.3 Update OpenSpec evidence and repo docs to reflect proxy mode as the intended default again.
