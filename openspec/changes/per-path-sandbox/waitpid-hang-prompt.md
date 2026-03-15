# Bug: `cmd.output()` hangs after sandboxed builder exits on Redox OS

## Problem

On Redox OS, `std::process::Command::output()` hangs indefinitely after a sandboxed builder process exits successfully. The builder runs in a child namespace where `file:` is a userspace proxy scheme. The builder completes its work (writes to `$out`, closes all fds), but the parent snix process never returns from `cmd.output()`.

Without the sandbox (normal builds), `cmd.output()` works correctly.

## Architecture

```
snix process (parent)
├── main thread: cmd.output() → spawn child → read pipes → waitpid
└── proxy thread: scheme event loop (file: proxy for child namespace)

child process (builder)
├── pre_exec: setns(child_ns_fd) → switches to child namespace
└── exec: /nix/system/profile/bin/bash -c "echo snix-build-works > $out"
```

### Namespace setup

1. `mkns(["debug", "log", "sys", ...])` — creates child namespace with those schemes but WITHOUT `file:`
2. `BuildFsProxy::start(child_ns_fd, allow_list)` — creates a scheme socket, registers our proxy as `file:` in child_ns_fd
3. Child calls `setns(child_ns_fd)` in `pre_exec`, then execs bash
4. All `file:` operations from child route through our proxy
5. Parent calls `cmd.output()` which internally does: spawn → read stdout/stderr pipes → waitpid

### What works

The proxy functions correctly. Verified via serial output:

```
buildfs: openat "/nix/system/profile/bin/bash" perm=ReadOnly    ← exec finds bash
buildfs: read id=2 len=578516 off=0 => 578516                  ← 4MB binary loaded
buildfs: openat "/etc/hostname" perm=ReadOnly                   ← bash init
buildfs: openat "/etc/passwd" perm=ReadOnly
buildfs: openat "/homeless-shelter/.bashrc" perm=Denied         ← allow-list blocks
buildfs: openat "/nix/store/...-snix-build-test" perm=ReadWrite ← $out opened
buildfs: write id=5 len=17 => 17                               ← "snix-build-works\n"
buildfs: close id=5                                             ← $out closed
buildfs: close id=2                                             ← bash binary closed
                                                                ← (no more requests)
```

After `close id=2`, the proxy event loop waits for the next request. No more arrive. The child's bash has exited. But snix's `cmd.output()` never returns.

## How `cmd.output()` works on Redox

`cmd.output()` calls `cmd.spawn()` then `child.wait_with_output()`:

1. **spawn**: Creates stdout/stderr pipes, forks, child closes read-ends, parent closes write-ends
2. **wait_with_output**: Reads from stdout/stderr pipe read-ends until EOF, then calls `waitpid()`
3. **EOF on pipes**: Happens when ALL write-ends are closed (i.e., when the child exits)

Pipes on Redox use the kernel's `pipe:` scheme — they do NOT route through the namespace manager or our `file:` proxy. So pipe I/O should be unaffected by the sandbox.

## Key Redox internals

### Namespace management is in userspace (relibc)

`setns()` modifies a process-global static `DYNAMIC_PROC_INFO.ns_fd` in relibc. It does NOT change anything in the kernel. It only affects which fd is passed to `SYS_OPENAT` by relibc's `open()`.

```rust
// relibc: redox-rt/src/sys.rs
pub fn setns(fd: usize) -> Option<FdGuardUpper> {
    let mut info = DYNAMIC_PROC_INFO.lock();
    let new_fd_guard = FdGuard::new(fd).to_upper().unwrap();
    let old_fd_guard = replace(&mut info.ns_fd, Some(new_fd_guard));
    old_fd_guard
}
```

### waitpid goes through proc: scheme

```rust
// relibc: redox-rt/src/sys.rs
pub fn sys_waitpid(target, status, flags) -> Result<usize> {
    wrapper(true, false, || {
        this_proc_call(
            unsafe { plain::as_mut_bytes(status) },
            CallFlags::empty(),
            &[ProcCall::Waitpid as u64, pid as u64, flags.bits() as u64],
        )
    })
}
```

`this_proc_call` writes to the process's `proc:` fd. The `proc:` scheme is handled by `procmgr` (a userspace daemon). `waitpid` blocks the parent until the child exits and procmgr sends SIGCHLD.

### Fork and fd inheritance

After `fork()`, the child inherits all of the parent's fds including:
- The scheme socket (from `Socket::create()`)
- The root_fd (from `File::open("/")`)
- The child_ns_fd (from `mkns()`)
- The stdout/stderr pipe write-ends (from `cmd.spawn()`)

The child then calls `setns(child_ns_fd)` and `exec(bash)`. On successful exec, CLOEXEC fds are closed. The scheme socket has CLOEXEC (set by `Socket::create`). The pipe write-ends do NOT have CLOEXEC (they become the child's stdout/stderr).

## Hypotheses

### H1: pipe write-end leak in proxy thread

If the proxy thread somehow holds a copy of the stdout/stderr pipe write-ends, EOF will never be delivered to the parent's read-ends. `cmd.output()` would block on `read()` forever.

**Evidence against**: The pipes are created inside `cmd.spawn()` which runs AFTER the proxy thread is spawned. The proxy thread doesn't have access to the pipe fds.

**BUT**: After `fork()`, the child has ALL parent fds. If the child's exec succeeds and closes CLOEXEC fds, non-CLOEXEC fds (pipes) stay open only in the child. When bash exits, those are closed → EOF. This should work.

### H2: SIGCHLD / waitpid doesn't fire for namespace-switched children

The child called `setns()` (which modifies relibc's `DYNAMIC_PROC_INFO.ns_fd`). After exec, the child has a FRESH relibc (exec replaces the process image). The new relibc initializes with the default namespace (inherited from the kernel's context, not from the parent's `DYNAMIC_PROC_INFO`).

But maybe `procmgr`'s waitpid tracking relies on something that breaks when the child is in a different namespace? procmgr tracks parent-child relationships, and the child is still the same PID / same parent. The namespace change shouldn't affect process hierarchy.

### H3: child hangs on exit cleanup

After bash finishes executing `echo ... > $out`, bash needs to exit. During exit, bash closes all its fds. Some of these fds route through our proxy (via the child namespace's `file:` scheme). The proxy handles `OnClose` events (verified — we see `close id=5` and `close id=2`). After closing all fds, bash calls `_exit()`.

But maybe bash does additional `file:` operations during exit that block? For example, flushing stdout (stdout is a pipe, not file:, so this shouldn't block). Or writing to a history file (blocked by allow-list, returns EACCES — bash should handle this gracefully).

### H4: scheme socket fd inherited by child blocks exit

The child inherits the scheme socket fd. After `exec()`, if the scheme socket fd has CLOEXEC, it's closed. If NOT, the child keeps it open. When bash exits, `_exit()` closes all fds including the scheme socket. Closing the scheme socket in the child might confuse the kernel — the scheme socket is owned by the parent (the scheme handler), and the child has a dup.

On Redox, a scheme socket fd represents the scheme handler's endpoint. If the child closes its copy, the kernel might decrement the reference count. If the parent's event loop is in `next_request()`, this shouldn't cause issues (the parent still has the fd). But maybe the kernel sends an error or EOF to the parent's event loop when the child's copy is closed?

### H5: cmd.output() read blocks because stdout pipe is still open

The child redirects stdout to `$out` (`echo ... > $out`). After the redirect, bash's stdout fd still exists (it points to the original pipe from cmd.spawn()). When bash writes to stdout while redirect is active, output goes to `$out`. After the redirect command completes, bash's stdout reverts to the pipe. But bash doesn't write anything else to stdout before exiting.

When bash exits, fd 1 (stdout, the pipe write-end) is closed. The parent should get EOF on the read-end. Unless... there's another process that still has the pipe write-end open?

## Relevant code locations

- `snix-redox/src/local_build.rs` lines 297-370: sandbox setup + `cmd.output()` call
- `snix-redox/src/sandbox.rs` lines 206-265: `setup_proxy_namespace()`
- `snix-redox/src/build_proxy/lifecycle.rs`: proxy start + event loop
- `snix-redox/src/build_proxy/handler.rs`: scheme handler (openat/read/write/close)
- relibc: `redox-rt/src/sys.rs` — `open()`, `setns()`, `sys_waitpid()`
- relibc: `redox-rt/src/lib.rs` — `current_namespace_fd()`, `DYNAMIC_PROC_INFO`
- relibc: `redox-rt/src/proc.rs` — fork, exec, process lifecycle
- kernel: `src/scheme/user.rs` — UserInner::call() blocks caller, scheme request dispatch
- kernel: `src/syscall/process.rs` — fork, exec, exit syscalls

## What I need

1. **Identify why `cmd.output()` hangs** — is it stuck in `read()` (pipe EOF never arrives) or in `waitpid()` (child exit never detected)?

2. **Find the specific mechanism** — trace through the fork/exec/exit path to find what's different when the child calls `setns()` before exec.

3. **Propose a fix** — either in snix (e.g., close inherited fds in pre_exec, restructure cmd.output() to avoid the hang) or document what kernel/relibc change is needed.

## Constraints

- Cannot modify the Redox kernel or relibc (those are upstream dependencies)
- The fix must be in snix-redox code (local_build.rs, sandbox.rs, build_proxy/)
- The proxy thread must stay alive until cmd.output() returns (it serves file I/O for the builder)
- AGENTS.md has detailed Redox platform constraints — read it before proposing changes
