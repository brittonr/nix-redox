## Context

Every subprocess invocation in Redox self-hosting requires a 3-line poll-wait workaround:

```bash
cmd & PID=$!
while kill -0 $PID 2>/dev/null; do cat /scheme/sys/uname >/dev/null 2>/dev/null; done
wait $PID
```

Without this, a bare `wait $PID` deadlocks when the parent process is idle. The workaround appears at 16 call sites in `self-hosting-test.nix`, once in `build-ripgrep.sh`, and implicitly in `snix-redox/src/local_build.rs` (which uses `Stdio::inherit()` + `status()` instead of `cmd.output()` to sidestep pipe-related hangs in deep process trees).

The hang only manifests on KVM (Cloud Hypervisor). `nanosleep` works correctly — the kernel's `SYS_NANOSLEEP` and scheduler wake path are verified. The pattern of "idle parent blocks forever, active parent succeeds" points to a scheduler or event delivery issue.

### Two proc schemes

Redox has two separate `proc:` schemes, and earlier analysis confused them:

| | Kernel ProcScheme | Userspace procmgr |
|---|---|---|
| Location | `kernel/src/scheme/proc.rs` | `bootstrap/src/procmgr.rs` (2591 lines) |
| Handles | Context management (regs, addrspace, signals) | POSIX process lifecycle (fork, waitpid, kill, pgid, sessions) |
| kcall verbs | Only `ProcSchemeVerb::Iopl` (255) | All 16 `ProcCall` variants including Waitpid |
| Used by | Bootstrap process only (kernel metadata fds) | All regular processes (via namespace) |

After boot, every process's `proc_fd` points to the **userspace procmgr**, not the kernel's ProcScheme. The kernel correctly routes `SYS_CALL` to the userspace scheme via its SQE/CQE mechanism. The procmgr implements full POSIX-compliant `waitpid()` with blocking, WNOHANG, process groups.

**waitpid IS fully implemented and works correctly.** The hang is not a missing feature.

### Actual hang mechanism (diagnosed)

**Root cause: Cloud Hypervisor does not deliver PIT (IRQ 0) interrupts when all vCPUs are in HLT.**

The Redox kernel scheduler runs exclusively inside the PIT interrupt handler chain:
- `pit_stack` (IRQ 0, vector 32) → `timeout::trigger()` → `context::switch::tick()` → `switch()`
- `switch()` → `update_runnable()` checks `context.wake` → unblocks expired `nanosleep`

The kernel's idle loop in `run_userspace()` (main.rs:246) does:
```rust
SwitchResult::AllContextsIdle => interrupt::enable_and_halt()  // STI; HLT
```

When all processes block (bash in nanosleep/poll, ion in waitpid, procmgr in next_event), all CPUs enter HLT. The PIT should fire IRQ 0 to wake a CPU, but Cloud Hypervisor doesn't deliver it. QEMU does.

Evidence:
- Functional test: 137/144 pass on CH, then hangs at `timed-wait-returns` (bash `read -t 1`)
- Same test: 141/144 pass on QEMU (passes timed-wait-returns)
- Hang reproduces with 1 CPU (rules out IPI)
- Procmgr instrumentation: last event at t=87096ms, then silence for 300+ seconds
- No THREAD_DIED for PID 480 ever arrives

The poll-wait workaround works because `cat /scheme/sys/uname` keeps a CPU active via continuous syscalls. Active syscalls call `context::switch()`, which runs the scheduler and eventually checks `context.wake` times. This prevents all CPUs from entering HLT simultaneously.

## Goals / Non-Goals

**Goals:**
- Identify why the procmgr's event loop stalls on KVM when the system is otherwise idle — whether it's a scheduler wake issue, an interrupt delivery issue (HLT exit), or an SQE/CQE delivery issue.
- Fix the root cause so `wait $PID` works without scheme I/O polling.
- Remove all poll-wait workarounds from test scripts and build scripts.
- Validate that `cmd.output()` (pipe-based process wait) also works, potentially enabling snix to drop the `Stdio::inherit()` workaround.

**Non-Goals:**
- Rewriting the procmgr. waitpid is correctly implemented — the fix is in event delivery or scheduling.
- Fixing unrelated poll() issues (jobserver pipe polling is separately patched).
- Changing how Ion shell implements `wait` (Ion calls relibc, which calls proc:).
- Upstreaming to Redox yet. Get it working in our fork first.

## Decisions

### 1. Diagnosis-first approach — instrument procmgr event loop

**Choice**: Add timestamps to the procmgr's event loop and the kernel's SQE delivery path before writing any fix. The bug is subtle (only on KVM, only when idle) and the earlier diagnosis was wrong — we can't afford another wrong guess.

**Alternatives considered**:
- **Shotgun fix — add a timer-based fallback wake in procmgr**: Would mask the bug without understanding it, and the timer adds latency. The poll-wait workaround is already this approach.
- **Bisect Redox kernel commits**: The hang has been present since our first KVM boot. No regression to bisect.

**Rationale**: We now know the procmgr is a single-threaded event-loop daemon. The question is whether SQEs are enqueued but procmgr never wakes to read them (scheduler/interrupt issue), or whether the SQE delivery itself stalls (kernel routing issue). Timestamps on both sides answer this definitively.

### 2. Confirmed: PIT not firing on Cloud Hypervisor

The failure path is now known:
1. All processes block (bash in nanosleep, ion in waitpid, procmgr in next_event)
2. All CPUs enter HLT via `run_userspace()` → `interrupt::enable_and_halt()`
3. PIT should fire IRQ 0 at ~246 Hz (4.1ms period) to wake a CPU
4. Cloud Hypervisor doesn't deliver PIT IRQ 0 to HLTing vCPUs
5. No CPU wakes → scheduler never runs → `context.wake` never checked → permanent hang

Cloud Hypervisor focuses on modern virtio devices and may not fully emulate the legacy PIT timer. It uses KVM_CREATE_PIT2 but IRQ routing for the PIT may not work when all CPUs are halted.

### 3. Fix: LAPIC timer for scheduling on KVM

**Choice**: Add LAPIC timer support to the Redox kernel scheduler. When running on KVM (detected via `tsc::get_kvm_support()`), use the LAPIC timer instead of PIT for scheduler ticks. Fall back to PIT on non-KVM platforms.

**Rationale**: The LAPIC timer is per-CPU, managed entirely by KVM's in-kernel emulation, and reliably wakes CPUs from HLT (it's the primary mechanism Linux uses for scheduling on KVM). Cloud Hypervisor supports full LAPIC emulation (it's required for all inter-CPU communication via IPI).

**Alternatives considered**:
- **Fix Cloud Hypervisor's PIT emulation**: Out of scope — we don't control CH. Also, relying on legacy PIT is fragile on modern VMMs.
- **procmgr busy-loop instead of event wait**: Would waste CPU and defeat the purpose.
- **procmgr timeout-based polling on event queue**: Adds latency (up to timeout interval). Better than busy-loop but still a workaround.
- **KVM paravirtualized timer (kvmclock)**: Already used for timekeeping (monotonic()), but the issue is scheduling, not time measurement. LAPIC timer is the right tool for periodic scheduling interrupts.

### 4. Staged workaround removal

Remove poll-wait patterns only after the fix is validated on a full self-hosting build. The snix `Stdio::inherit()` workaround is removed in a separate step after confirming `cmd.output()` works for deep process hierarchies (builder→cargo→rustc→cc→lld).

## Risks / Trade-offs

- **[Risk] Root cause is in a third layer**: The tracing may reveal the issue is not in SQE delivery or scheduler wake but somewhere else (e.g., procmgr blocks on a different resource, or the kernel's scheme routing stalls). → Mitigated by instrumenting both sides (kernel SQE enqueue + procmgr event loop).
- **[Risk] Fix works on KVM but breaks QEMU or bare metal**: Different hypervisors handle HLT and interrupt injection differently. → Test on both QEMU and Cloud Hypervisor after fixing.
- **[Risk] Removing Stdio::inherit() exposes a different pipe bug**: The deep-process pipe crash may be independent of the waitpid issue. → Keep it as a separate validation step (Phase 4), revert if pipe crashes return.
- **[Risk] Kernel patch affects other scheme daemons**: Orbital, audiod, and other event-driven daemons use the same SQE/CQE and event infrastructure. → The fix must be in the wake-delivery path specifically, not a broad event semantics change. Run the graphical profile as a regression test.
- **[Risk] Earlier diagnosis wasted tasks**: 5 completed tasks were based on incorrect analysis (confused kernel ProcScheme with userspace procmgr). → Superseded but documented — the code reading still informed the corrected understanding.
- **[Trade-off] Restarting diagnosis adds time**: Another boot-test cycle for tracing. Worth it — the first round proved that guessing the wrong layer wastes more time than careful instrumentation.
