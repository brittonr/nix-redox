## ADDED Requirements

### Requirement: Guest validation covers representative C and C++ build-system classes

The repo SHALL maintain a guest-native validation gauntlet that covers at least three representative classes: a Rust crate using `cc-rs`, an autotools-style C package, and a cmake-based C++ package.

#### Scenario: Representative gauntlet runs on guest
- **WHEN** the guest-native C/C++ gauntlet runs
- **THEN** it executes one fixture for each required build-system class
- **AND** each fixture emits a PASS or FAIL verdict

### Requirement: Gauntlet failures capture wrapper and sysroot diagnostics

If a gauntlet stage fails, the harness SHALL capture the compiler or linker command, the wrapper path, and the key sysroot/resource-dir settings used for that stage.

#### Scenario: C fixture fails in compiler wrapper
- **WHEN** a gauntlet stage fails during compilation or linking
- **THEN** the failure output records the command that failed
- **AND** records the relevant wrapper, linker, and sysroot settings
- **AND** identifies which fixture class failed

### Requirement: Wrapper and sysroot changes run against the gauntlet

Changes that modify the Redox C/C++ wrapper path, linker invocation, sandbox allow-list for toolchain binaries, or sysroot packaging SHALL run the guest-native C/C++ gauntlet before the change is treated as validated.

#### Scenario: cc wrapper changes trigger gauntlet
- **WHEN** a change updates the `cc` wrapper or clang resource-dir/sysroot behavior
- **THEN** the representative guest-native C/C++ gauntlet is run
- **AND** the change is not considered validated without that result
