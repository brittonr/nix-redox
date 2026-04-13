## Why

Redox self-hosting is now credible for Rust-first workloads, but the C/C++ ecosystem remains much less boring. Toolchain wrappers, sysroot paths, autotools/cmake behavior, and package-specific workarounds still surface as recurring pain. The next step is to stop treating C/C++ support as anecdotal and instead validate it as a deliberate gauntlet.

## What Changes

- Define a representative guest-native C/C++ package gauntlet instead of relying on one-off success stories.
- Cover multiple build-system classes: plain cc-rs, autotools-style C packages, and cmake/C++ builds.
- Improve failure diagnostics so wrapper, linker, header, and sysroot issues are visible immediately.
- Make the gauntlet a standing validation gate for changes that touch wrappers, sysroots, sandboxing, or C/C++ packaging rules.

## Capabilities

### New Capabilities
- `native-c-package-gauntlet`: Validate guest-native C and C++ package builds through a representative, repeatable test matrix instead of isolated anecdotes.

### Modified Capabilities

None.

## Impact

- **Validation**: new guest test fixtures and bundles for representative C/C++ packages.
- **Tooling**: clang/cc wrapper behavior, sysroot paths, linker invocation, and diagnostics.
- **Packaging**: common patterns for autotools, cmake, and mixed Rust+C crates.
- **Docs**: clearer statement of what classes of non-Rust packages are currently supported.
