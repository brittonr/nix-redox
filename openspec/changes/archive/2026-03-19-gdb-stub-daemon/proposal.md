## Why

We have the gdb-protocol library (GDB Remote Serial Protocol wire format) and the kernel already implements the full debugging infrastructure — proc: scheme for register/memory access, ptrace module for breakpoints and single-stepping, hardware int3/debug exception handling on x86_64. strace-redox proves the userspace API works. What's missing is the translation layer that lets a remote GDB client debug processes on Redox over TCP. Without it, bare metal debugging means printf and kernel serial traces.

## What Changes

- New **gdbstub** daemon that runs on Redox, listens on TCP, and translates GDB RSP commands into proc: scheme operations
- Maps RSP `g`/`G` (read/write registers) to `proc:<pid>/regs/int` and `proc:<pid>/regs/float`
- Maps RSP `m`/`M` (read/write memory) to `proc:<pid>/mem` with seek
- Maps RSP `s` (single step) to ptrace STOP_SINGLESTEP via `proc:<pid>/trace`
- Maps RSP `c` (continue) to ptrace continue
- Maps RSP `Z0`/`z0` (software breakpoints) to int3 patching via `proc:<pid>/mem`
- Maps RSP `?` (stop reason) to ptrace event queue
- Maps RSP `Hg`/`Hc` (thread select) to proc: scheme PID targeting
- Attaches to a target process by PID, similar to how strace-redox works
- Reuses the strace-redox `Tracer`/`Memory`/`Registers` API patterns (open proc: files, read/write structs)
- Reuses gdb-protocol crate for packet parsing and encoding
- Added to development profile so `gdbstub <pid>` is available alongside strace

## Capabilities

### New Capabilities
- `gdb-stub-core`: The daemon binary — TCP listener, RSP command dispatch, proc: scheme integration
- `gdb-stub-package`: Nix packaging, flake wiring, profile integration

### Modified Capabilities

## Impact

- New Rust crate in `src/gdbstub/` (or separate repo)
- `nix/pkgs/userspace/gdbstub.nix`: cross-compiled package
- `nix/flake-modules/packages.nix`: package wiring
- `nix/flake-modules/system.nix`: extraPkgs entry
- `nix/redox-system/profiles/development.nix`: added to systemPackages
- Dependencies: gdb-protocol, redox_syscall (already in our build)
- No kernel changes required — all infrastructure already exists
