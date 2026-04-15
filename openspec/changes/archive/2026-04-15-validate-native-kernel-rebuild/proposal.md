## Why

Current Redox self-hosting proof is strongest for userspace: rustc, cargo, snix, package builds, and rebuild flows. The missing next rung is native kernel and bootloader rebuild evidence on a running Redox guest. Until that exists, the project can honestly claim userspace self-hosting, but full OS self-hosting still has a visible gap.

## What Changes

- Add a focused guest-native build path for the Redox kernel and bootloader from source bundles or declared source trees.
- Add a VM test that builds those artifacts natively on Redox and records durable PASS/FAIL evidence.
- Verify the resulting store outputs can be staged into a boot selection flow, with at least one smoke path proving the rebuilt artifacts are consumable.
- Document the exact scope of what "native kernel rebuild" means in the current tree.

## Capabilities

### New Capabilities
- `native-kernel-rebuild-validation`: Prove that Redox can build its own kernel and bootloader artifacts natively on a guest and surface durable evidence for that claim.

### Modified Capabilities

None.

## Impact

- **Build/test profiles**: new source bundles, focused VM profiles, and guest build scripts.
- **snix/system integration**: artifact staging and possibly boot-generation smoke validation.
- **Docs/evidence**: self-hosting claim ladder becomes explicit about userspace vs kernel proof.
- **Storage/runtime**: kernel-native builds are heavier than current focused userspace checks.
