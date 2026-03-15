#!/usr/bin/env python3
"""Add timestamp instrumentation to procmgr's event loop.

Logs key events at warn level so they show at the default BOOTSTRAP_LOG_LEVEL.
Each log line includes a monotonic timestamp (ms since boot) and event type.

Usage: python3 patch-procmgr-instrument.py bootstrap/src/procmgr.rs
"""

import sys

def patch(path):
    with open(path, "r") as f:
        src = f.read()

    # 1. Add timing imports after the existing use statements
    # Find the last "use syscall::" line and add after it
    marker = "use crate::KernelSchemeMap;"
    if marker not in src:
        print(f"ERROR: cannot find '{marker}' in {path}", file=sys.stderr)
        sys.exit(1)

    timing_code = '''use crate::KernelSchemeMap;

// --- INSTRUMENTATION: monotonic timestamp helper ---
fn now_ms() -> u64 {
    let mut ts = syscall::data::TimeSpec { tv_sec: 0, tv_nsec: 0 };
    let _ = syscall::clock_gettime(syscall::CLOCK_MONOTONIC, &mut ts);
    (ts.tv_sec as u64) * 1000 + (ts.tv_nsec as u64) / 1_000_000
}
// --- END INSTRUMENTATION ---'''
    src = src.replace(marker, timing_code, 1)

    # 2. Instrument the main event loop: log when next_event() returns
    # Find: let event = queue.next_event().expect("failed to get next event");
    old_next_event = 'let event = queue.next_event().expect("failed to get next event");'
    new_next_event = '''let _t_before = now_ms();
        let event = queue.next_event().expect("failed to get next event");
        let _t_after = now_ms();
        let _wait_ms = _t_after.wrapping_sub(_t_before);
        if event.data == socket_ident {
            log::warn!("[PROCMGR t={}ms wait={}ms] EVENT: scheme socket (SQE ready)", _t_after, _wait_ms);
        } else {
            log::warn!("[PROCMGR t={}ms wait={}ms] EVENT: fd={} flags={:?}", _t_after, _wait_ms, event.data, event.flags);
        }'''
    if old_next_event not in src:
        print(f"ERROR: cannot find next_event call in {path}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_next_event, new_next_event, 1)

    # 3. Instrument SQE reading: log each request type
    # Find the REQ trace log and add a warn-level log
    old_req_log = 'log::trace!("REQ{req:#?}");'
    # Log the SQE opcode byte by reading it from the Request's memory layout.
    # Request is repr(C) and starts with Sqe whose first byte is the opcode.
    new_req_log = '''log::trace!("REQ{req:#?}");
                {
                    let opcode = unsafe { *(&req as *const _ as *const u8) };
                    let name = match opcode { 5 => "Dup", 6 => "Read", 22 => "Close", 26 => "Call", 30 => "OpenAt", _ => "Other" };
                    log::warn!("[PROCMGR t={}ms] SQE: op={} ({})", now_ms(), opcode, name);
                }'''
    if old_req_log not in src:
        print(f"ERROR: cannot find REQ trace log in {path}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_req_log, new_req_log, 1)

    # 4. Instrument CQE writing (response back to caller) in the request loop
    # Use the unique anchor: handle_scheme returning Ready(resp)
    old_resp_write = '''let Ready(resp) =
                    handle_scheme(req, &socket, &mut scheme, &mut states, &mut awoken)
                else {
                    continue 'reqs;
                };
                loop {'''
    new_resp_write = '''let Ready(resp) =
                    handle_scheme(req, &socket, &mut scheme, &mut states, &mut awoken)
                else {
                    continue 'reqs;
                };
                log::warn!("[PROCMGR t={}ms] CQE: writing response", now_ms());
                loop {'''
    if old_resp_write not in src:
        print(f"ERROR: cannot find handle_scheme Ready(resp) pattern in {path}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_resp_write, new_resp_write, 1)

    # 5. Instrument waitpid-specific path: log when waitpid returns Ready vs Pending
    old_waitpid_log = '''log::trace!(
                    "WAITPID {req_id:?}, {waiter:?}: {target:?} flags {flags:?} -> {res:?}"
                );'''
    new_waitpid_log = '''log::trace!(
                    "WAITPID {req_id:?}, {waiter:?}: {target:?} flags {flags:?} -> {res:?}"
                );
                log::warn!("[PROCMGR t={}ms] WAITPID: waiter={:?} target={:?} result={}", now_ms(), waiter, target, if res.is_ready() { "Ready" } else { "Pending" });'''
    if old_waitpid_log not in src:
        print(f"ERROR: cannot find WAITPID trace log in {path}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_waitpid_log, new_waitpid_log, 1)

    # 6. Instrument thread death handling
    old_thread_died = 'log::trace!("--THREAD DIED {}, {}", event.data, thread.pid.0);'
    new_thread_died = '''log::trace!("--THREAD DIED {}, {}", event.data, thread.pid.0);
            log::warn!("[PROCMGR t={}ms] THREAD_DIED: fd={} pid={}", now_ms(), event.data, thread.pid.0);'''
    if old_thread_died not in src:
        print(f"ERROR: cannot find THREAD DIED trace log in {path}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_thread_died, new_thread_died, 1)

    # 7. Instrument waitpid_waiting drain (parent wake-up)
    old_awake_log = 'log::trace!("AWAKING WAITPID {:?}", parent.waitpid_waiting);'
    new_awake_log = '''log::trace!("AWAKING WAITPID {:?}", parent.waitpid_waiting);
                        log::warn!("[PROCMGR t={}ms] WAKE_WAITERS: count={} for parent of exited pid={:?}", now_ms(), parent.waitpid_waiting.len(), current_pid);'''
    if old_awake_log not in src:
        print(f"ERROR: cannot find AWAKING WAITPID log in {path}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_awake_log, new_awake_log, 1)

    # 8. Add kind_name() helper to Request (for readable SQE logging)
    # We need to add a method that returns a string for the request kind.
    # Actually, Request is from redox_scheme crate - we can't add methods.
    # Instead, use a free function.
    # No helper function needed — we log the opcode directly from the SQE byte

    # 9. Add startup log
    old_started = 'log::debug!("process manager started");'
    new_started = '''log::warn!("[PROCMGR t={}ms] Process manager started (instrumented)", now_ms());'''
    if old_started not in src:
        print(f"ERROR: cannot find 'process manager started' log in {path}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_started, new_started, 1)

    with open(path, "w") as f:
        f.write(src)

    print(f"Patched {path} with procmgr instrumentation")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-procmgr.rs>", file=sys.stderr)
        sys.exit(1)
    patch(sys.argv[1])
