## Context

The repo already has good evidence for userspace self-hosting and host-side boot-component rebuilding, but no durable guest-native proof that Redox can rebuild the kernel and bootloader artifacts from inside a running Redox system. Kernel builds use a different target flow than normal userspace packages, so we should not treat existing cargo/snix success as sufficient proof. We need a focused path that is explicit about what is being built, where sources come from, and what result counts as success.

## Goals / Non-Goals

**Goals:**
- Build the Redox kernel natively on a guest and produce a store output from that build.
- Build the bootloader natively on a guest or explicitly document why it remains out of scope if the source path differs.
- Capture durable evidence and a repeatable command/test flow for future regressions.

**Non-Goals:**
- Replace the existing host-side bridge path for routine boot component rebuilds.
- Prove every platform-specific firmware interaction from guest-native builds in the first pass.
- Fold kernel-native validation into the already-large self-hosting suite immediately.

## Decisions

### 1. Use a dedicated focused VM test instead of the full self-hosting suite first

**Choice:** Add a standalone focused validation for kernel/bootloader-native builds.

**Rationale:** Kernel-native builds are heavier and slower than the existing userspace checks. A focused test gives clearer failure signals and keeps iteration time manageable.

**Alternative considered:** Insert kernel-native builds directly into `self-hosting-test`. Rejected for the first pass because it would make an already expensive suite harder to debug.

### 2. Treat build proof and boot proof as separate stages

**Choice:** First prove the guest can produce the kernel and bootloader store outputs. Then add a smaller smoke stage showing those outputs can be staged into boot selection or reboot validation.

**Rationale:** Producing the artifacts is the primary self-hosting proof. Booting them is a second layer with different failure modes.

**Alternative considered:** Require immediate full reboot proof before accepting any native build artifact. Rejected because it couples compile correctness to every runtime boot variable at once.

### 3. Make artifact provenance explicit

**Choice:** The focused validation will record exactly which source bundle or checkout was used, which command built it, and where the resulting store outputs were written.

**Rationale:** Without provenance, a later reader cannot tell whether the guest truly built the artifact or merely reused a prebuilt output.

**Alternative considered:** Rely only on pueue logs or serial snippets. Rejected because they are too easy to lose and too weak for this milestone.

### 4. Ship one audited guest bundle with kernel, bootloader, and rust-src inputs

**Choice:** The first slice uses a single guest-visible bundle at `/usr/src/native-kernel-rebuild` with `kernel/`, `bootloader/`, `rust-src/library`, a bundle manifest, and the focused guest test script.

**Rationale:** Kernel and bootloader rebuilds share the same guest toolchain and proof harness, while `-Z build-std` needs Rust library sources that the guest test can read without network access. One audited bundle keeps provenance and guest paths simple.

**Alternative considered:** Separate kernel and bootloader bundles, or relying on the guest toolchain package to provide rust-src implicitly. Rejected for the first slice because it spreads provenance across multiple paths and makes the offline input contract harder to audit.

## Risks / Trade-offs

- **Very long guest build times** → Use a focused profile, heartbeat logging, and durable capture directories.
- **Boot smoke failures hide compile success** → Keep build-artifact proof separate from reboot smoke validation.
- **Source bundle drift** → Record source provenance and audit the bundle contents before the guest boots.

## Migration Plan

1. Define the focused guest-native kernel/bootloader source bundles.
2. Add the focused VM test and durable capture output.
3. Validate the build-artifact proof first.
4. Add a staged boot smoke path once the build proof is reliable.

## Proof status after the first focused pass

- The focused `kernel-rebuild-test` now proves that a running Redox guest can rebuild both the kernel and the bootloader from the audited `/usr/src/native-kernel-rebuild` bundle and emit guest-produced `/nix/store/...` outputs for each artifact.
- The proof remains intentionally narrower than full OS self-hosting. It does not yet prove that those guest-produced outputs have been staged into the boot artifact selection flow or that the VM has rebooted with them.
- This focused flow is therefore a separate proof rung from the existing `self-hosting-test` baseline. `self-hosting-test` still covers userspace self-hosting and rebuild flows; `kernel-rebuild-test` covers guest-native boot-component artifact production.

## Open Questions

- Whether the first-pass boot smoke should reboot the same VM or stage artifacts only and validate manifest/boot selection plumbing.
