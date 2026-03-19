## Context

The Redox kernel has a fully implemented ptrace module (`src/ptrace.rs`) with Session management, breakpoint callbacks, event queues, and wait/notify. The syscall entry/exit paths (`arch/x86_64/interrupt/syscall.rs`), exception handlers (`arch/x86_shared/interrupt/exception.rs`), and signal delivery code all call `ptrace::breakpoint_callback()` and `ptrace::send_event()`.

The problem: these functions check `Session::current()`, which reads `PercpuBlock.ptrace_session`. But nothing writes to that field — the context switch code that would load it is **commented out**:

```rust
// In context/switch.rs:
/*let (ptrace_session, ptrace_flags) = if let Some((session, bp)) = ptrace::sessions()
    .get(&next_context.pid)
    .map(|s| (Arc::downgrade(s), s.data.lock().breakpoint))
{
    (Some(session), bp.map_or(PtraceFlags::empty(), |f| f.flags))
} else {
    (None, PtraceFlags::empty())
};*/
let ptrace_flags = PtraceFlags::empty();
//*percpu.ptrace_session.borrow_mut() = ptrace_session;
```

The old code used a global `ptrace::sessions()` registry keyed by PID. That registry no longer exists. The replacement needs to store the session reference on the Context struct itself, then load it during context switch.

The proc scheme has `regs/int`, `regs/float`, `addrspace`, `status`, etc. but no `trace` or `mem` paths — those were removed when the sessions registry was removed.

## Goals / Non-Goals

**Goals:**
- Restore userspace ptrace access via `proc:<pid>/trace` and `proc:<pid>/mem`
- Make `strace-redox` work (validates the interface matches what existing tools expect)
- Make gdbstub work (validates register read/write, memory access, breakpoints)
- Minimal kernel changes — reuse existing ptrace module, don't redesign it

**Non-Goals:**
- Multi-tracer support (one tracer per process, same as before)
- Hardware breakpoints/watchpoints (DR0-DR3 access)
- Kernel-mode debugging (would need a kernel stub, separate project)
- Changing the ptrace event format or flags

## Decisions

### 1. Store session on Context, not in a global registry

The old design had a global `HashMap<PID, Arc<Session>>`. The new design stores `Option<Weak<Session>>` directly on the `Context` struct. This avoids the global lock contention and matches how other per-context state (addr_space, files, sig) is stored.

When opening `proc:<pid>/trace`, create a `Session`, store `Arc<Session>` in the `ContextHandle::Trace` variant, and store `Weak<Session>` on the target `Context`.

Context switch loads the session from the incoming context into `percpu.ptrace_session`.

### 2. Trace handle: read events, write breakpoint flags

```
open("proc:<pid>/trace") → ContextHandle::Trace { session: Arc<Session> }
read → drain PtraceEvent queue (Session.data.recv_events)
write → set PtraceFlags breakpoint mask (Session.data.set_breakpoint)
fevent → EVENT_READ when events pending
close → close_session, clear context's weak ref
```

The read/write semantics match what strace-redox expects:
- Write `PtraceFlags::bits().to_ne_bytes()` to set what stops to listen for
- Read returns `PtraceEvent` structs from the queue
- Blocking: read blocks (via `ptrace::wait`) until event available

### 3. Memory handle: seek + read/write through target page tables

```
open("proc:<pid>/mem") → ContextHandle::Memory { addrspace: Arc<AddrSpaceWrapper> }
seek(addr) → set offset
read(buf) → translate virtual address through target page tables, copy bytes
write(buf) → translate, write bytes (for int3 patching)
```

The `AddrSpace` already has page table walking in `utable.translate()`. For each page boundary, translate the virtual address to physical, then read/write the physical memory. This is the same operation the kernel debugger in `debugger.rs` does (it switches page tables and reads directly, but we can do it more safely through the translation API).

### 4. Kernel patch, not upstream fork

Apply as a Python patch script (matching our existing pattern: `patch-kernel-*.py` files in `nix/pkgs/system/`). The patch modifies `src/scheme/proc.rs`, `src/context/context.rs` (add session field), and `src/context/switch.rs` (uncomment and fix session loading).

### 5. Context field: `ptrace_session: Option<Weak<Session>>`

Add to the `Context` struct. Set when a tracer opens `proc:<pid>/trace`. Cleared on `close_session`. Read during context switch to populate `percpu.ptrace_session`.

## Risks / Trade-offs

**[Page table walk safety]** → Reading another process's memory through page tables is inherently unsafe. The target must be stopped (not running on any CPU) before reading, otherwise the page tables could change mid-read. Mitigation: use `try_stop_context()` (already in proc.rs) before memory operations.

**[Session lifetime]** → If the tracer dies without closing the trace handle, the Session's `Weak` ref on the Context becomes dangling. `Session::current()` returns `None`, ptrace callbacks become no-ops. The tracee resumes normally. This is the correct behavior — orphaned tracees shouldn't stay stopped forever.

**[Context switch overhead]** → Loading `ptrace_session` from Context adds one `Option<Weak<Session>>` clone per context switch. This is a single atomic increment — negligible compared to page table switching.

**[Compatibility with strace-redox]** → strace-redox uses redox_syscall 0.3.4. Our gdbstub uses 0.5. The wire format (PtraceEvent struct, PtraceFlags bitfield) must match between kernel and userspace. The struct layouts haven't changed between syscall crate versions — just the module organization.
