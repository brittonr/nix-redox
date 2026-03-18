## Context

The Redox kernel exposes process debugging through the proc: scheme:

```
proc:<pid>/regs/int    — read/write IntRegisters struct (rax, rbx, ..., rip, rsp, rflags)
proc:<pid>/regs/float  — read/write FloatRegisters struct (xmm0-15, mxcsr, etc.)
proc:<pid>/mem         — seek to address, read/write process memory
proc:<pid>/trace       — write PtraceFlags to set breakpoint, read PtraceEvent queue
```

strace-redox already exercises this API. Its `Tracer` struct (lib.rs) demonstrates the full pattern: open files, fork+SIGSTOP the child, attach, set breakpoint flags, wait for events, read registers, read memory.

The gdb-protocol crate handles the GDB RSP wire format — `$packet#checksum` encoding/decoding, TCP accept, ack/nack.

GDB connects from a remote machine (or localhost) to a stub that speaks RSP. The stub translates RSP commands to target-specific operations. Our stub translates to proc: scheme operations.

## Goals / Non-Goals

**Goals:**
- Debug any userspace process on Redox from a remote GDB client
- Support core RSP commands: read/write registers, read/write memory, continue, single step, software breakpoints, stop reason query
- Attach to an existing process by PID
- Launch and debug a new process
- Work over TCP (GDB's `target remote <ip>:<port>`)

**Non-Goals:**
- Kernel debugging (would need a kernel-mode stub, different architecture)
- Hardware breakpoints/watchpoints (DR0-DR3 — proc: scheme doesn't expose debug registers yet)
- Multi-threaded debugging (Redox doesn't have kernel threads per-process in the Linux sense — each "thread" is a separate context/PID)
- Shared library event notifications (no dl_debug_state equivalent)
- Reverse debugging, tracepoints, or other extended GDB features

## Decisions

### 1. Standalone binary, not a scheme daemon

gdbstub runs as a regular binary, not a scheme. It opens proc: scheme files like strace does. No need for a custom scheme — all the kernel primitives are already exposed.

Usage: `gdbstub <pid> [port]` or `gdbstub --exec /bin/program [port]`

### 2. Reuse strace-redox's Tracer API patterns, not the crate directly

strace-redox's lib.rs is the reference for how to use proc:/ptrace from userspace. We replicate the same file-based patterns (open `proc:<pid>/regs/int`, read struct, etc.) rather than depending on the strace crate, because strace bundles syscall formatting logic we don't need and its API is oriented toward tracing, not debugging.

### 3. Register mapping: IntRegisters → GDB x86_64 register file

GDB's x86_64 register file layout (from gdb/features/i386/64bit-core.xml):

```
rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp,
r8-r15, rip, eflags, cs, ss, ds, es, fs, gs
```

Redox's `IntRegisters` (from redox_syscall) contains all of these. We need to serialize them in GDB's expected order for the `g` response and deserialize `G` writes back.

FloatRegisters maps to the `fpregset` — xmm0-15, mxcsr, etc. This is the `p`/`P` extended register set.

### 4. Software breakpoints via memory patching

RSP `Z0,addr,kind` (insert breakpoint) and `z0,addr,kind` (remove):
- Read original byte at addr via `proc:<pid>/mem`
- Write `0xCC` (int3) to addr
- Store original byte for restoration
- On `z0`, write original byte back

This is exactly what strace-redox's `Memory::set_breakpoint` does.

### 5. TCP transport, not serial

GDB connects via `target remote <ip>:<port>`. The gdb-protocol crate already has `GdbServer::listen()` which does TCP accept. Default port 1234 (GDB convention).

For bare metal debugging over serial, a future extension could use `/dev/ttyS*` instead of TCP. The RSP framing is transport-agnostic.

### 6. Source location: `src/gdbstub/` in our repo

Small focused crate (~800-1200 lines). Lives in our repo since it's specific to our build. Dependencies: gdb-protocol (RSP framing), redox_syscall (IntRegisters/FloatRegisters types, ptrace flags).

## Risks / Trade-offs

**[relibc poll() for TCP]** → relibc's poll() is unreliable for pipe multiplexing (AGENTS.md). TCP sockets should work but may need thread-based I/O instead of poll-based multiplexing if the tracee blocks. Mitigation: use blocking I/O on the GDB connection — one client at a time, no multiplexing needed.

**[Process doesn't stop cleanly]** → If the target is in a syscall when we attach, registers may reflect kernel state. Mitigation: strace-redox handles this (SIGSTOP + waitpid pattern). Follow the same approach.

**[Memory read across page boundaries]** → `proc:<pid>/mem` seek+read may fail at unmapped pages. Mitigation: return GDB error packet `E14` (EFAULT) for failed reads rather than crashing.

**[No DWARF awareness]** → The stub doesn't parse debug info — GDB does that. But GDB needs the ELF binary on the host side for source-level debugging. Users must copy the binary or use `set sysroot`. This is standard for remote debugging — not a stub limitation.
