## 1. Define the representative gauntlet

- [ ] 1.1 Select one `cc-rs` fixture, one autotools-style C fixture, and one cmake/C++ fixture that represent the main Redox failure classes.
- [ ] 1.2 Build guest-visible source bundles or fixtures for those packages.
- [ ] 1.3 Document why each fixture exists and which wrapper/sysroot behavior it protects.

## 2. Improve harness diagnostics

- [ ] 2.1 Capture compiler, linker, and wrapper command lines when a gauntlet stage fails.
- [ ] 2.2 Capture the key environment variables and sysroot/resource-dir paths used by the failing stage.
- [ ] 2.3 Emit concise PASS/FAIL verdicts that still include actionable failure context.

## 3. Make the gauntlet pass

- [ ] 3.1 Run the initial gauntlet on the guest and classify current failures by wrapper, linker, header, or package issue.
- [ ] 3.2 Fix the shared toolchain or packaging blockers exposed by the gauntlet.
- [ ] 3.3 Re-run until the representative fixtures pass end to end.

## 4. Turn it into a standing regression gate

- [ ] 4.1 Hook the gauntlet into the validation workflow used for wrapper/sysroot/sandbox changes.
- [ ] 4.2 Update docs so non-Rust support is described by tested build-system classes.
- [ ] 4.3 Attach durable evidence from a passing gauntlet run.
