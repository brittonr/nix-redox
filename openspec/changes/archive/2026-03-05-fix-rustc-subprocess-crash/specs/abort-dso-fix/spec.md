## ADDED Requirements

### Requirement: abort() in DSO relibc copies must not crash with ud2
The relibc `abort()` function SHALL NOT execute `ud2` when the abort hook function pointer is NULL. When the hook is uninitialized (as occurs in DSO copies of relibc), `abort()` MUST call `_exit(134)` to terminate the process with a recognizable exit code (128 + SIGABRT = 134).

#### Scenario: DSO abort with uninitialized hook
- **WHEN** code in librustc_driver.so (or any DSO with bundled relibc) calls `abort()`
- **THEN** the process SHALL terminate with exit code 134, and the parent process (cargo) SHALL receive a clean waitpid result indicating child failure
- **AND** the kernel SHALL NOT print an "Invalid opcode fault" register dump

#### Scenario: Main binary abort with initialized hook
- **WHEN** code in the main binary calls `abort()` and the abort hook is properly initialized
- **THEN** the abort hook function SHALL be called as before (no behavioral change)

### Requirement: /etc/hosts must exist in the disk image
The Redox disk image SHALL include `/etc/hosts` with at minimum a localhost entry. This prevents `gethostent()` from failing when it opens `/etc/hosts`.

#### Scenario: gethostent reads /etc/hosts
- **WHEN** a program calls `gethostent()` to resolve host entries
- **THEN** the function SHALL successfully open and read `/etc/hosts`
- **AND** `127.0.0.1 localhost` SHALL be present in the file

### Requirement: cargo build with build.rs must succeed
After the abort and /etc/hosts fixes, `cargo build` of a project containing `build.rs` with `println!("cargo:rustc-cfg=...")` and `println!("cargo:rustc-env=...")` directives SHALL complete successfully on Redox.

#### Scenario: build script directives applied
- **WHEN** `cargo build` is run on a project with `build.rs` that emits `cargo:rustc-cfg=has_buildscript` and `cargo:rustc-env=BUILD_TARGET=<target>`
- **THEN** cargo SHALL compile the build script, execute it, read the directives, and compile `src/main.rs` with the cfg and env values
- **AND** the resulting binary SHALL execute and print output confirming the build-script-injected values are accessible

#### Scenario: self-hosting test reports PASS
- **WHEN** the self-hosting test suite runs Step 10
- **THEN** the test SHALL report `FUNC_TEST:cargo-buildrs:PASS`

### Requirement: diagnostic output for crash investigation
The self-hosting test Step 10 SHALL capture and display cargo's verbose output (`-vv`) so that if the build fails, the exact rustc invocation and error message are visible in the test log.

#### Scenario: verbose cargo output captured on failure
- **WHEN** the `cargo build` in Step 10 fails
- **THEN** the test SHALL display the cargo stderr output (up to 4KB) including the full rustc command line from `-vv` mode
