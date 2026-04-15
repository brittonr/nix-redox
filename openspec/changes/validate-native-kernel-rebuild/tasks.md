## 1. Define the guest-native build inputs

- [x] 1.1 Identify the exact kernel and bootloader source trees, toolchain inputs, and bundle layout the guest-native test will use.
- [x] 1.2 Build source bundles or fixture paths that make those inputs available offline inside the guest.
- [x] 1.3 Add bundle auditing so the test records which sources were actually provided.

## 2. Add focused guest-native validation

- [x] 2.1 Add a focused VM profile/test that runs the native kernel build on Redox and records the resulting store path.
- [x] 2.2 Extend the same focused path to build the bootloader natively or explicitly report a blocked state with evidence.
- [x] 2.3 Emit FUNC_TEST verdicts and heartbeat/progress logs suitable for long guest build times.

## 3. Prove the artifacts are consumable

- [ ] 3.1 Validate that the guest-produced artifacts can be registered/staged in the system's boot artifact flow.
- [ ] 3.2 Add a boot smoke path that proves the rebuilt artifacts can be selected for boot, if practical in the focused VM.
- [x] 3.3 Record artifact provenance and resulting store paths in the durable capture output.

## 4. Document the self-hosting claim

- [x] 4.1 Document what this change proves about kernel-native self-hosting and what still remains out of scope.
- [x] 4.2 Update roadmap/baseline notes so userspace and kernel-native proof are no longer conflated.
- [x] 4.3 Attach durable evidence excerpts from a passing focused run.
