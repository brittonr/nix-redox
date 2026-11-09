#!/usr/bin/env python3
"""Restore ptrace proc: scheme handles in the Redox kernel.

The kernel has a complete ptrace module (Session, breakpoint callbacks,
event queues, wait/notify) but no userspace interface. The proc: scheme's
trace and mem handles were removed when the global session registry was
deleted. This patch restores them:

1. Context struct: add ptrace_session field (Option<Weak<Session>>)
2. Context switch: load ptrace session from context into percpu
3. Proc scheme: add Trace handle (read events, write flags, fevent, close)
4. Proc scheme: add Memory handle (seek+read/write target virtual memory)

After this patch, strace-redox and gdbstub can open proc:<pid>/trace and
proc:<pid>/mem to debug processes.
"""

import sys
import os


def patch_file(filepath, old, new):
    with open(filepath, "r") as f:
        content = f.read()
    if content.count(old) != 1:
        raise SystemExit(f"{filepath}: expected exactly one ptrace patch anchor: {old[:100]!r}")
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print(f"  Patched {filepath}")
    return True


def patch_context_struct(src_dir):
    """Add ptrace_session field to Context struct and its imports."""

    context_file = os.path.join(src_dir, "src/context/context.rs")

    # Add import for ptrace::Session and Weak
    patch_file(
        context_file,
        "use alloc::{collections::BTreeSet, sync::Arc, vec::Vec};",
        "use alloc::{collections::BTreeSet, sync::{Arc, Weak}, vec::Vec};",
    )

    # Add ptrace import to the crate-level imports
    patch_file(
        context_file,
        """use crate::{
    arch::interrupt::InterruptStack,""",
        """use crate::{
    arch::interrupt::InterruptStack,
    ptrace,""",
    )

    # Add ptrace_session field to Context struct (after being_sigkilled)
    patch_file(
        context_file,
        "    pub being_sigkilled: bool,\n    pub fmap_ret: Option<Frame>,",
        "    pub being_sigkilled: bool,\n    /// Ptrace session for this context (set when a tracer attaches)\n    pub ptrace_session: Option<Weak<ptrace::Session>>,\n    pub fmap_ret: Option<Frame>,",
    )

    # Initialize ptrace_session to None in Context::new()
    patch_file(
        context_file,
        "            being_sigkilled: false,",
        "            being_sigkilled: false,\n            ptrace_session: None,",
    )

    print("Context struct patched: ptrace_session field added")


def patch_context_switch(src_dir):
    """Restore ptrace session loading in context switch."""

    switch_file = os.path.join(src_dir, "src/context/switch.rs")

    # Replace the commented-out ptrace session loading with working code
    # that reads from the context's ptrace_session field
    patch_file(
        switch_file,
        """    /*let (ptrace_session, ptrace_flags) = if let Some((session, bp)) = ptrace::sessions()
        .get(&next_context.pid)
        .map(|s| (Arc::downgrade(s), s.data.lock().breakpoint))
    {
        (Some(session), bp.map_or(PtraceFlags::empty(), |f| f.flags))
    } else {
        (None, PtraceFlags::empty())
    };*/
    let ptrace_flags = PtraceFlags::empty();

    //*percpu.ptrace_session.borrow_mut() = ptrace_session;
    percpu.ptrace_flags.set(ptrace_flags);""",
        """    // Load the incoming context's tracing session for breakpoint callbacks.
    let (ptrace_session, ptrace_flags) = match next_context.ptrace_session {
        Some(ref weak) => {
            if let Some(session) = weak.upgrade() {
                let flags = session.data.lock().breakpoint.as_ref()
                    .map_or(PtraceFlags::empty(), |b| b.flags);
                (Some(weak.clone()), flags)
            } else {
                (None, PtraceFlags::empty())
            }
        }
        None => (None, PtraceFlags::empty()),
    };
    *percpu.ptrace_session.borrow_mut() = ptrace_session;
    percpu.ptrace_flags.set(ptrace_flags);""",
    )

    print("Context switch patched: ptrace session loading restored")


def patch_proc_scheme(src_dir):
    """Add Trace and Memory handle variants to the proc: scheme."""

    proc_file = os.path.join(src_dir, "src/scheme/proc.rs")

    # Add needed imports at top of file
    patch_file(
        proc_file,
        "    memory::{Page, VirtualAddress, PAGE_SIZE},",
        "    memory::{Page, PhysicalAddress, RmmA, VirtualAddress, PAGE_SIZE},",
    )

    patch_file(
        proc_file,
        "    mem::size_of,",
        "    mem::{self, size_of},",
    )

    patch_file(
        proc_file,
        """use alloc::{
    boxed::Box,
    string::String,
    sync::{Arc, Weak},
    vec::Vec,
};""",
        """use alloc::{
    boxed::Box,
    string::String,
    sync::{Arc, Weak},
    vec::Vec,
};
use rmm::Arch;""",
    )

    # Add PtraceFlags import
    patch_file(
        proc_file,
        "use ::syscall::{ProcSchemeAttrs, SigProcControl, Sigcontrol};",
        "use ::syscall::{ProcSchemeAttrs, PtraceFlags, SigProcControl, Sigcontrol};",
    )

    # Add Trace and Memory variants to ContextHandle enum
    patch_file(
        proc_file,
        """    // TODO: Remove this once openat is implemented, or allow openat-via-dup via e.g. the top-level
    // directory.
    OpenViaDup,""",
        """    Trace {
        session: Arc<ptrace::Session>,
        target: Arc<ContextLock>,
    },
    Memory {
        addrspace: Arc<crate::context::memory::AddrSpaceWrapper>,
        target: Arc<ContextLock>,
    },
    // TODO: Remove this once openat is implemented, or allow openat-via-dup via e.g. the top-level
    // directory.
    OpenViaDup,""",
    )

    # Add "trace" and "mem" paths to openat_context()
    patch_file(
        proc_file,
        """            "sched-affinity" => (ContextHandle::SchedAffinity, true),
            "status" => (ContextHandle::Status { privileged: false }, false),""",
        """            "sched-affinity" => (ContextHandle::SchedAffinity, true),
            "status" => (ContextHandle::Status { privileged: false }, false),
            "trace" => {
                // Check if already traced
                let ctx = context.read(token.token());
                if ctx.ptrace_session.as_ref().and_then(|w| w.upgrade()).is_some() {
                    return Err(Error::new(EBUSY));
                }
                drop(ctx);

                // Create a new ptrace session. Use the proc handle id as file_id
                // for event notifications.
                let file_id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
                let session = ptrace::Session::new(file_id);

                // Store weak reference on the target context
                {
                    let mut ctx = context.write(token.token());
                    ctx.ptrace_session = Some(Arc::downgrade(&session));
                }

                (ContextHandle::Trace { session, target: Arc::clone(&context) }, false)
            }
            "mem" => {
                let addrspace = Arc::clone(
                    context
                        .read(token.token())
                        .addr_space()
                        .map_err(|_| Error::new(ENOENT))?,
                );
                (ContextHandle::Memory {
                    addrspace,
                    target: Arc::clone(&context),
                }, true)
            }""",
    )

    # Add fevent support for Trace handle
    patch_file(
        proc_file,
        """    fn fevent(
        &self,
        id: usize,
        _flags: EventFlags,
        token: &mut CleanLockToken,
    ) -> Result<EventFlags> {
        let handles = HANDLES.read(token.token());
        let _handle = handles.get(&id).ok_or(Error::new(EBADF))?;

        Ok(EventFlags::empty())
    }""",
        """    fn fevent(
        &self,
        id: usize,
        _flags: EventFlags,
        token: &mut CleanLockToken,
    ) -> Result<EventFlags> {
        let handles = HANDLES.read(token.token());
        let handle = handles.get(&id).ok_or(Error::new(EBADF))?;

        match &handle.kind {
            ContextHandle::Trace { session, .. } => {
                Ok(session.data.lock().session_fevent_flags())
            }
            _ => Ok(EventFlags::empty()),
        }
    }""",
    )

    # Add close handling for Trace handle (before the existing AddrSpace close)
    patch_file(
        proc_file,
        """        match handle {
            Handle {
                context,
                kind:
                    ContextHandle::AwaitingAddrSpaceChange {""",
        """        match handle {
            Handle {
                context,
                kind: ContextHandle::Trace { session, target },
            } => {
                // Clear the session from the target context
                {
                    let mut ctx = target.write(token.token());
                    ctx.ptrace_session = None;
                }
                // Close the session (notify waiters)
                ptrace::close_session(&session, token);
            }
            Handle {
                context,
                kind: ContextHandle::Memory { .. },
            } => {
                // Nothing special on close
            }
            Handle {
                context,
                kind:
                    ContextHandle::AwaitingAddrSpaceChange {""",
    )

    # Add read support for Trace handle in kreadoff
    patch_file(
        proc_file,
        """            // TODO: Find a better way to switch address spaces, since they also require switching
            // the instruction and stack pointer. Maybe remove `<pid>/regs` altogether and replace it
            // with `<pid>/ctx`
            _ => Err(Error::new(EBADF)),""",
        """            ContextHandle::Trace { session, .. } => {
                // Report ESRCH once the tracee is gone and events are drained.
                if session.data.lock().is_closed_empty() {
                    return Err(Error::new(ESRCH));
                }
                // Wait for events if none pending (check via fevent flags)
                if session.data.lock().session_fevent_flags().is_empty() {
                    ptrace::wait(Arc::clone(session), token)?;
                }
                if session.data.lock().is_closed_empty() {
                    return Err(Error::new(ESRCH));
                }
                // Drain events into output buffer
                let event_size = mem::size_of::<crate::syscall::data::PtraceEvent>();
                let max_events = buf.len() / event_size;
                if max_events == 0 {
                    return Err(Error::new(EINVAL));
                }
                let mut events = alloc::vec![crate::syscall::data::PtraceEvent::default(); max_events];
                let count = session.data.lock().recv_events(&mut events);
                if count == 0 {
                    return Ok(0);
                }
                let src = unsafe {
                    slice::from_raw_parts(
                        events.as_ptr() as *const u8,
                        count * event_size,
                    )
                };
                buf.copy_common_bytes_from_slice(src)
            }
            ContextHandle::Memory { addrspace, target } => {
                // Read target process memory. The offset (from lseek/file descriptor)
                // is the virtual address in the target's address space.
                let virt_addr = offset as usize;
                let read_len = buf.len();

                // Allocate kernel buffer for the read
                let mut kbuf = alloc::vec![0u8; read_len];

                // Must stop the target for safe page table access
                let total_read = try_stop_context(Arc::clone(target), token, |_target_ctx, lock_token| {
                    let guard = addrspace.acquire_read(lock_token);
                    let mut total = 0usize;
                    let mut current_addr = virt_addr;

                    while total < read_len {
                        let page_offset = current_addr % PAGE_SIZE;
                        let chunk = core::cmp::min(read_len - total, PAGE_SIZE - page_offset);

                        let page = Page::containing_address(VirtualAddress::new(current_addr));

                        match guard.table.utable.translate(page.start_address()) {
                            Some((phys_base, _flags)) => {
                                let phys_addr = phys_base.data() + page_offset;
                                let src_ptr = unsafe {
                                    RmmA::phys_to_virt(PhysicalAddress::new(phys_addr)).data()
                                        as *const u8
                                };
                                unsafe {
                                    core::ptr::copy_nonoverlapping(src_ptr, kbuf.as_mut_ptr().add(total), chunk);
                                }
                            }
                            None => {
                                if total == 0 {
                                    return Err(Error::new(EFAULT));
                                }
                                break;
                            }
                        }
                        current_addr += chunk;
                        total += chunk;
                    }

                    Ok(total)
                })?;

                buf.copy_common_bytes_from_slice(&kbuf[..total_read])
            }
            // TODO: Find a better way to switch address spaces, since they also require switching
            // the instruction and stack pointer. Maybe remove `<pid>/regs` altogether and replace it
            // with `<pid>/ctx`
            _ => Err(Error::new(EBADF)),""",
    )

    # Add write support for Trace handle in ContextHandle::kwriteoff
    # Insert before the existing OpenViaDup write handler
    patch_file(
        proc_file,
        """            ContextHandle::OpenViaDup => {
                let mut args = buf.usizes();

                let user_data = args.next().ok_or(Error::new(EINVAL))??;

                let context_verb =
                    ContextVerb::try_from_raw(user_data).ok_or(Error::new(EINVAL))?;

                match context_verb {
                    ContextVerb::ForceKill => {
                        if context::is_current(&context) {""",
        """            Self::Trace { session, target } => {
                // Write PtraceFlags (u64 LE) to set breakpoint mask
                if buf.len() < mem::size_of::<u64>() {
                    return Err(Error::new(EINVAL));
                }
                let mut raw_bits = [0_u8; 8];
                buf.limit(8).ok_or(Error::new(EINVAL))?.copy_to_slice(&mut raw_bits)?;
                let bits = u64::from_ne_bytes(raw_bits);
                let flags = PtraceFlags::from_bits_truncate(bits);
                let mut data = session.data.lock();
                data.set_breakpoint(Some(flags));
                // Notify the tracee to continue (it may be waiting in breakpoint_callback)
                session.tracee.notify(token);
                Ok(mem::size_of::<u64>())
            }
            ContextHandle::OpenViaDup => {
                let mut args = buf.usizes();

                let user_data = args.next().ok_or(Error::new(EINVAL))??;

                let context_verb =
                    ContextVerb::try_from_raw(user_data).ok_or(Error::new(EINVAL))?;

                match context_verb {
                    ContextVerb::ForceKill => {
                        if context::is_current(&context) {""",
    )

    # Add write support for Memory handle in ProcScheme::kwriteoff (scheme level,
    # where _offset is available). Intercept Memory before dispatching to ContextHandle.
    patch_file(
        proc_file,
        """        let Handle { context, kind } = handle;
        kind.kwriteoff(id, context, buf, token)""",
        """        let Handle { context, kind } = handle;

        // Handle Memory writes at scheme level where offset is available
        if let ContextHandle::Memory { ref addrspace, ref target } = kind {
            let virt_addr = _offset as usize;
            let src_len = buf.len();

            let mut src_buf = alloc::vec![0u8; src_len];
            buf.copy_to_slice(&mut src_buf)?;

            return try_stop_context(Arc::clone(target), token, |_target_ctx, lock_token| {
                let guard = addrspace.acquire_read(lock_token);
                let mut total_written = 0usize;
                let mut remaining = src_len;
                let mut current_addr = virt_addr;

                while remaining > 0 {
                    let page_offset = current_addr % PAGE_SIZE;
                    let chunk = core::cmp::min(remaining, PAGE_SIZE - page_offset);
                    let page = Page::containing_address(VirtualAddress::new(current_addr));

                    match guard.table.utable.translate(page.start_address()) {
                        Some((phys_base, _flags)) => {
                            let phys_addr = phys_base.data() + page_offset;
                            let dst_ptr = unsafe {
                                RmmA::phys_to_virt(PhysicalAddress::new(phys_addr)).data()
                                    as *mut u8
                            };
                            let dst_slice = unsafe { slice::from_raw_parts_mut(dst_ptr, chunk) };
                            dst_slice.copy_from_slice(&src_buf[total_written..total_written + chunk]);
                        }
                        None => {
                            if total_written == 0 {
                                return Err(Error::new(EFAULT));
                            }
                            break;
                        }
                    }
                    current_addr += chunk;
                    total_written += chunk;
                    remaining -= chunk;
                }
                Ok(total_written)
            });
        }

        kind.kwriteoff(id, context, buf, token)""",
    )

    # Add kopenat AND kdup support for "PID/operation" paths from Authority handle
    # On Redox, relibc's open("proc:PID/trace") resolves through the namespace
    # system which uses dup(scheme_root_fd, "PID/trace") — NOT kopenat.
    # We need to handle these paths in BOTH kdup (Authority) and kopenat.

    # Patch kdup to handle "PID/operation" paths from Authority
    patch_file(
        proc_file,
        """                Handle {
                    kind: ContextHandle::Authority,
                    ..
                } => {
                    return self
                        .open_inner(
                            OpenTy::Auth,
                            Some(core::str::from_utf8(buf).map_err(|_| Error::new(EINVAL))?)
                                .filter(|s| !s.is_empty()),
                            O_RDWR,
                            token,
                        )
                        .map(|(r, fl)| OpenResult::SchemeLocal(r, fl))
                }""",
        """                Handle {
                    kind: ContextHandle::Authority,
                    ..
                } => {
                    let path = core::str::from_utf8(buf).map_err(|_| Error::new(EINVAL))?;

                    // Handle "PID/operation" paths (e.g. "27/trace", "27/mem")
                    // This is how relibc routes open("proc:27/trace") — via dup
                    if let Some(slash_pos) = path.find('/') {
                        let pid_str = &path[..slash_pos];
                        let operation = &path[slash_pos + 1..];
                        if let Ok(pid) = pid_str.parse::<usize>() {
                            // Find context by PID
                            let context_lock = {
                                let all_ctx: alloc::vec::Vec<Arc<ContextLock>> = context::contexts(token.downgrade())
                                    .iter()
                                    .map(|ctx_ref| Arc::clone(&ctx_ref.0))
                                    .collect();
                                let mut found = None;
                                for ctx_lock in all_ctx {
                                    if ctx_lock.read(token.token()).pid == pid {
                                        found = Some(ctx_lock);
                                        break;
                                    }
                                }
                                found.ok_or(Error::new(ESRCH))?
                            };
                            return self
                                .open_inner(
                                    OpenTy::Ctxt(context_lock),
                                    Some(operation).filter(|s| !s.is_empty()),
                                    O_RDWR,
                                    token,
                                )
                                .map(|(r, fl)| OpenResult::SchemeLocal(r, fl));
                        }
                    }

                    return self
                        .open_inner(
                            OpenTy::Auth,
                            Some(path).filter(|s| !s.is_empty()),
                            O_RDWR,
                            token,
                        )
                        .map(|(r, fl)| OpenResult::SchemeLocal(r, fl))
                }""",
    )

    # Also add kopenat for tools that may use it directly
    patch_file(
        proc_file,
        """impl KernelScheme for ProcScheme {
    fn scheme_root(&self, token: &mut CleanLockToken) -> Result<usize> {""",
        """impl KernelScheme for ProcScheme {
    fn kopenat(
        &self,
        file: usize,
        path: crate::scheme::StrOrBytes,
        flags: usize,
        _fcntl_flags: u32,
        _ctx: CallerCtx,
        token: &mut CleanLockToken,
    ) -> Result<OpenResult> {
        let path_str = match path {
            crate::scheme::StrOrBytes::Str(s) => s,
            _ => return Err(Error::new(EINVAL)),
        };

        let handles = HANDLES.read(token.token());
        let handle = handles.get(&file).ok_or(Error::new(EBADF))?;

        match &handle.kind {
            ContextHandle::Authority => {
                drop(handles);

                let (pid_str, operation) = match path_str.find('/') {
                    Some(pos) => (&path_str[..pos], Some(&path_str[pos + 1..])),
                    None => (path_str, None),
                };

                let pid: usize = pid_str.parse().map_err(|_| Error::new(ENOENT))?;

                let context_lock = {
                    let all_ctx: alloc::vec::Vec<Arc<ContextLock>> = context::contexts(token.downgrade())
                        .iter()
                        .map(|ctx_ref| Arc::clone(&ctx_ref.0))
                        .collect();
                    let mut found = None;
                    for ctx_lock in all_ctx {
                        if ctx_lock.read(token.token()).pid == pid {
                            found = Some(ctx_lock);
                            break;
                        }
                    }
                    found.ok_or(Error::new(ESRCH))?
                };

                if let Some(op) = operation {
                    self.open_inner(OpenTy::Ctxt(context_lock), Some(op), flags, token)
                        .map(|(r, fl)| OpenResult::SchemeLocal(r, fl))
                } else {
                    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
                    HANDLES.write(token.token()).insert(id, Handle {
                        context: context_lock,
                        kind: ContextHandle::OpenViaDup,
                    });
                    Ok(OpenResult::SchemeLocal(id, InternalFlags::empty()))
                }
            }
            ContextHandle::OpenViaDup => {
                let context = Arc::clone(&handle.context);
                drop(handles);
                self.open_inner(OpenTy::Ctxt(context), Some(path_str), flags, token)
                    .map(|(r, fl)| OpenResult::SchemeLocal(r, fl))
            }
            _ => Err(Error::new(EINVAL)),
        }
    }

    fn scheme_root(&self, token: &mut CleanLockToken) -> Result<usize> {""",
    )

    print("Proc scheme patched: Trace and Memory handles added")


def patch_breakpoint_semantics(src_dir):
    """Fix the restored ptrace breakpoint gate and signal-wake loop.

    The restored code stopped for events the tracer did NOT request, and its
    wait loop re-queued events when a signal (e.g. SIGCONT) kept wait() from
    blocking, exhausting the 1 MiB kernel heap.
    """

    ptrace_file = os.path.join(src_dir, "src/ptrace.rs")

    patch_file(
        ptrace_file,
        """        // TODO: Some or all flags?
        // Only stop if the tracer have asked for this breakpoint
        if percpu.ptrace_flags.get().contains(match_flags) {
            return None;
        }""",
        """        // Only stop if the tracer asked for this breakpoint.
        if !percpu.ptrace_flags.get().contains(match_flags) {
            return None;
        }""",
    )

    patch_file(
        ptrace_file,
        """        if session
            .tracee
            .wait(data, "ptrace::breakpoint_callback", &mut token)
        {
            // We successfully waited, wake up!
            break Some(breakpoint.flags);
        }
    }""",
        """        // The tracer continued us, or a signal is pending. Do not loop:
        // a pending signal makes wait() return immediately every time and
        // re-queues events until the 1 MiB kernel heap is exhausted.
        let _ = session
            .tracee
            .wait(data, "ptrace::breakpoint_callback", &mut token);
        break Some(breakpoint.flags);
    }""",
    )

    print("Breakpoint gate and signal-wake semantics patched")


def patch_tracee_exit(src_dir):
    """Notify the tracer when the tracee exits and report EOF as ESRCH."""

    ptrace_file = os.path.join(src_dir, "src/ptrace.rs")

    patch_file(
        ptrace_file,
        """pub struct SessionData {
    pub(crate) breakpoint: Option<Breakpoint>,
    events: VecDeque<PtraceEvent>,
    file_id: usize,
}""",
        """pub struct SessionData {
    pub(crate) breakpoint: Option<Breakpoint>,
    events: VecDeque<PtraceEvent>,
    closed: bool,
    file_id: usize,
}""",
    )

    patch_file(
        ptrace_file,
        """            data: Mutex::new(SessionData {
                breakpoint: None,
                events: VecDeque::new(),
                file_id,
            }),""",
        """            data: Mutex::new(SessionData {
                breakpoint: None,
                events: VecDeque::new(),
                closed: false,
                file_id,
            }),""",
    )

    patch_file(
        ptrace_file,
        """    /// Poll events, return the amount read. This drains events from the queue.""",
        """    pub fn is_closed_empty(&self) -> bool {
        self.closed && self.events.is_empty()
    }

    /// Poll events, return the amount read. This drains events from the queue.""",
    )

    patch_file(
        ptrace_file,
        """pub fn close_tracee(session: &Session, token: &mut CleanLockToken) {
    session.tracer.notify(token);

    let data = session.data.lock();
    proc_trigger_event(data.file_id, EVENT_READ, token);
}""",
        """pub fn close_tracee(session: &Session, token: &mut CleanLockToken) {
    session.data.lock().closed = true;
    session.tracer.notify(token);

    let data = session.data.lock();
    proc_trigger_event(data.file_id, EVENT_READ, token);
}""",
    )

    process_file = os.path.join(src_dir, "src/syscall/process.rs")

    patch_file(
        process_file,
        """    let context_lock = Arc::clone(&*context::current());
    let (addrspace_opt, mut close_files) = {
        let mut context = context_lock.write(token.token());
        let (context, token) = context.token_split();
        let close_files = Arc::try_unwrap(mem::take(&mut context.files))""",
        """    let context_lock = Arc::clone(&*context::current());
    let (addrspace_opt, mut close_files, ptrace_session) = {
        let mut context = context_lock.write(token.token());
        let (context, token) = context.token_split();
        let ptrace_session = context.ptrace_session.take().and_then(|weak| weak.upgrade());
        let close_files = Arc::try_unwrap(mem::take(&mut context.files))""",
    )

    patch_file(
        process_file,
        """        (addrspace_opt, close_files)
    };""",
        """        (addrspace_opt, close_files, ptrace_session)
    };""",
    )

    patch_file(
        process_file,
        """    // TODO: Should status == Status::HardBlocked be handled differently?
    let owner = {""",
        """    if let Some(session) = ptrace_session.as_ref() {
        crate::ptrace::close_tracee(session, token);
    }
    // TODO: Should status == Status::HardBlocked be handled differently?
    let owner = {""",
    )

    print("Tracee exit notification patched")


def patch_all(src_dir):
    patch_context_struct(src_dir)
    patch_context_switch(src_dir)
    patch_proc_scheme(src_dir)
    patch_breakpoint_semantics(src_dir)
    patch_tracee_exit(src_dir)
    print("\nAll ptrace proc handle patches applied successfully")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <kernel-source-dir>")
        sys.exit(1)
    patch_all(sys.argv[1])
