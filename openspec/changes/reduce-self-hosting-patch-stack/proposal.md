## Why

Redox self-hosting works today, but it depends on a large local patch stack across relibc, cargo, rustc, and related tooling. That patch pile makes upgrades expensive, hides which fixes are still truly required, and weakens the claim that the platform is converging toward maintainable native builds.

## What Changes

- Inventory every self-hosting patch that is currently applied to the toolchain and runtime.
- Classify patches by subsystem, purpose, upstream status, removal risk, and the test coverage that protects them.
- Create an explicit retirement workflow so patches can be removed one at a time with focused validation instead of by guesswork.
- Remove low-risk obsolete patches where the validation matrix proves they are no longer needed, and record blockers for the ones that remain.

## Capabilities

### New Capabilities
- `toolchain-patch-reduction`: Track, validate, and retire Redox self-hosting patches systematically instead of carrying an undocumented patch pile.

### Modified Capabilities

None.

## Impact

- **Build inputs**: relibc, cargo, rustc, llvm/lld wrappers, and package patch pipelines.
- **Validation**: host checks, focused VM tests, sandbox tests, and full self-hosting suites need to map cleanly onto patch classes.
- **Docs**: evidence for why each patch still exists or was removed.
- **Upstreaming**: creates a queue of patches that can move from local carry to upstream submission or deletion.
