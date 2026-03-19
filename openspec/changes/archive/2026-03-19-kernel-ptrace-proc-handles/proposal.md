## Why

The kernel has a complete ptrace infrastructure — Session management, breakpoint callbacks in syscall entry/exit and exception handlers, event queues, single-step and breakpoint stop reasons — but no userspace interface to access it. The proc: scheme's `trace` and `mem` handles were removed at some point during kernel development. Both strace-redox and our new gdbstub daemon fail with ENODEV/ENOSYS when trying to open `proc:<pid>/trace`.

Without these handles, no userspace debugger or tracer can function on Redox. The kernel does the hard work (interrupt hooking, context switching, event dispatch) but the last mile — letting userspace read events and control execution — is missing.

## What Changes

- Add **`ContextHandle::Trace`** to the proc: scheme — wraps a ptrace `Session`, read returns `PtraceEvent` structs, write sets `PtraceFlags` breakpoint mask. The ptrace module's `Session`, `send_event`, `breakpoint_callback`, and `wait` functions are already implemented and used internally.
- Add **`ContextHandle::Memory`** to the proc: scheme — read/write target process virtual memory by seeking to an address and reading/writing bytes. Uses the target's `AddrSpace` page table to translate virtual addresses and copy data.
- Both handles opened via `proc:<pid>/trace` and `proc:<pid>/mem` paths in `openat_context()`
- Wire the trace handle into the per-CPU ptrace session so the kernel's existing breakpoint callbacks (`breakpoint_callback` in syscall.rs, exception.rs) deliver events to the trace file's event queue

## Capabilities

### New Capabilities
- `proc-trace-handle`: The trace handle for ptrace session control via proc: scheme
- `proc-mem-handle`: The memory handle for cross-process memory access via proc: scheme

### Modified Capabilities

## Impact

- `kernel/src/scheme/proc.rs`: Two new `ContextHandle` variants, path matching, read/write implementations
- `kernel/src/ptrace.rs`: Session attachment from proc scheme (may need a `set_session` helper)
- `kernel/src/percpu.rs`: Existing `ptrace_session` field already exists — just needs wiring
- Kernel patch applied via our existing `nix/pkgs/system/` patch infrastructure
- No ABI changes — proc: scheme already exists, we're adding paths to it
- Unblocks: gdbstub daemon, strace-redox, any future userspace debugger
