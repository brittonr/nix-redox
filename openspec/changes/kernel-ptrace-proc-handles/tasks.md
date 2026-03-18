## 1. Context struct: add ptrace session field

- [x] 1.1 Add `pub ptrace_session: Option<Weak<Session>>` field to `Context` struct in `src/context/context.rs`
- [x] 1.2 Initialize to `None` in Context::new()
- [x] 1.3 Import `ptrace::Session` and `alloc::sync::Weak` in context module

## 2. Context switch: load ptrace session into percpu

- [x] 2.1 Uncomment and fix the ptrace_session loading in `src/context/switch.rs` — read from `next_context.ptrace_session` instead of the deleted global registry
- [x] 2.2 Load ptrace_flags from the session's breakpoint if present, empty if no session
- [x] 2.3 Verify `percpu.ptrace_session` is set before the context runs so `Session::current()` works

## 3. Proc scheme: add Trace handle

- [x] 3.1 Add `ContextHandle::Trace { session: Arc<Session> }` variant to the enum
- [x] 3.2 Add `"trace"` path to `openat_context()` match — create Session, store Weak on target Context, return Trace handle
- [x] 3.3 Check for existing session (return EBUSY if already traced)
- [x] 3.4 Implement read for Trace handle — call `session.data.lock().recv_events()`, block via `ptrace::wait()` if no events
- [x] 3.5 Implement write for Trace handle — parse PtraceFlags from bytes, call `session.data.lock().set_breakpoint()`
- [x] 3.6 Implement fevent for Trace handle — return EVENT_READ when `!session.data.lock().events.is_empty()`
- [x] 3.7 Implement close for Trace handle — call `ptrace::close_session()`, clear Context's weak ref

## 4. Proc scheme: add Memory handle

- [x] 4.1 Add `ContextHandle::Memory { addrspace: Arc<AddrSpaceWrapper> }` variant
- [x] 4.2 Add `"mem"` path to `openat_context()` match — clone the target's AddrSpace, return Memory handle (positioned)
- [x] 4.3 Implement read for Memory handle — use offset as virtual address, translate through utable, copy bytes
- [x] 4.4 Implement write for Memory handle — translate address, write bytes to target physical memory
- [x] 4.5 Handle page boundary crossing (translate per page)
- [x] 4.6 Handle unmapped addresses (return EFAULT)
- [x] 4.7 Wrap memory access in try_stop_context() for safety

## 5. Kernel patch integration

- [x] 5.1 Create `nix/pkgs/patches/kernel-ptrace-proc-handles.py` patch script
- [x] 5.2 Apply patch in kernel build (add to kernel.nix or base.nix patch phase)
- [x] 5.3 Rebuild kernel with patch: `nix build .#kernelPerCrate`

## 6. Validation

- [x] 6.1 Boot VM with patched kernel
- [ ] 6.2 Run `strace echo test` — verify ptrace events are received (pre/post syscall stops)
  - BLOCKED: `proc:` scheme is managed by procmgr (userspace), not directly accessible to user processes.
    Opening `proc:<pid>/trace` goes through procmgr's scheme handler which doesn't forward trace/mem.
    The kernel ProcScheme kopenat + kdup + trace/mem handles compile and are correct, but procmgr
    needs to be patched to forward "trace" and "mem" operations to the kernel's proc scheme.
    This is tracked as a follow-up change.
- [ ] 6.3 Run `gdbstub --exec /bin/ls --port 1234` — verify attach succeeds (no ENODEV)
- [ ] 6.4 Connect GDB from host, verify register read (`info registers`), memory read (`x/10i $rip`), single step (`si`), continue (`c`)
