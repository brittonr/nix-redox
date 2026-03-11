## ADDED Requirements

### Requirement: CC wrapper invokes lld with a grown stack

The cc wrapper SHALL invoke lld on a thread with at least 16MB of stack space, rather than inheriting the kernel's default ~8KB main-thread stack.

#### Scenario: Single link invocation succeeds
- **WHEN** cargo invokes the cc wrapper to link a binary with JOBS=1
- **THEN** lld runs on a 16MB-stack thread and produces the output binary without stack overflow

#### Scenario: Parallel link invocations succeed
- **WHEN** cargo invokes the cc wrapper twice concurrently (JOBS=2)
- **THEN** both lld invocations complete without `fatal runtime error` or `abort()` crashes

#### Scenario: Trivial program links under JOBS=2
- **WHEN** `fn main() { println!("hello"); }` is compiled and linked with JOBS=2
- **THEN** linking succeeds with exit code 0

### Requirement: Launcher binary wraps lld execution

A compiled Rust binary (`lld-wrapper`) SHALL exist that spawns a thread with 16MB stack and `exec()`s lld with all forwarded arguments from that thread.

#### Scenario: Arguments are forwarded to lld
- **WHEN** the launcher is invoked with arguments `arg1 arg2 ... argN`
- **THEN** lld receives exactly those same arguments in the same order

#### Scenario: Exit code is propagated
- **WHEN** lld exits with a non-zero code
- **THEN** the launcher process exits with the same code

#### Scenario: Exec failure is reported
- **WHEN** the lld binary path does not exist or is not executable
- **THEN** the launcher prints an error to stderr and exits with code 1

### Requirement: Bash cc wrapper uses the launcher for lld

The bash cc wrapper in `redox-sysroot.nix` SHALL invoke lld through the launcher binary instead of calling lld directly.

#### Scenario: Executable linking uses launcher
- **WHEN** the cc wrapper is invoked for an executable link (no `-shared` flag)
- **THEN** the wrapper calls the launcher binary with CRT objects, library flags, and lld arguments

#### Scenario: Shared library linking uses launcher
- **WHEN** the cc wrapper is invoked with `-shared` (proc-macro .so)
- **THEN** the wrapper calls the launcher binary with shared-link flags

### Requirement: Compiled cc-wrapper-redox uses spawn-thread pattern

The compiled cc wrapper in `cc-wrapper-redox.nix` SHALL spawn a thread with 16MB stack and `exec()` lld from that thread, rather than calling `exec()` from the main thread.

#### Scenario: Compiled wrapper spawns thread before exec
- **WHEN** the compiled cc wrapper is invoked
- **THEN** it spawns a new thread with 16MB stack size and calls `exec()` from that thread
