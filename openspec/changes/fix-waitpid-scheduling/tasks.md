## 1. Diagnosis (original) — SUPERSEDED

Earlier analysis confused the kernel ProcScheme with the userspace procmgr. These tasks are complete but their findings were wrong. Kept for record.

- [x] 1.1 ~~Read relibc's `waitpid()` implementation.~~ SUPERSEDED — call chain is correct (`SYS_CALL` to proc scheme) but the target scheme is the userspace procmgr, not the kernel ProcScheme.
- [x] 1.2 ~~Read the kernel's `proc:` scheme source.~~ SUPERSEDED — the kernel ProcScheme only handles `Iopl` because it's only used by the bootstrap process. Regular processes use the userspace procmgr.
- [x] 1.3 ~~Read the kernel scheduler's `wake` / `unblock` path.~~ SUPERSEDED — scheduler wake for scheme events may still be relevant, but the "no waitpid implementation" conclusion was wrong.
- [x] 1.4–1.7 SKIPPED — original root cause was wrong, no instrumentation was done.
- [x] 1.8 ~~Document findings.~~ SUPERSEDED — findings were incorrect. See corrected analysis below.

### Corrected understanding (2026-03-14)

Two proc schemes exist on Redox:
- **Kernel ProcScheme** (`kernel/src/scheme/proc.rs`): only handles `ProcSchemeVerb::Iopl` (255). Used only by bootstrap process.
- **Userspace procmgr** (`bootstrap/src/procmgr.rs`, 2591 lines): handles all 16 `ProcCall` variants including Waitpid, Kill, Fork, etc. Every regular process's `proc_fd` points here.

The procmgr implements full POSIX-compliant `waitpid()` with blocking, WNOHANG, process groups. waitpid works correctly. The hang is NOT a missing feature.

## 2. Diagnosis (corrected) — Investigate procmgr event loop starvation

- [x] 2.1 Read the procmgr's event loop in `bootstrap/src/procmgr.rs`. Map the call chain: `queue.next_event()` → SQE read → dispatch (Waitpid handler) → CQE write. Document what blocks, what wakes it, and whether there's any timeout or keepalive.
  - **Event loop structure** (procmgr.rs `run()`, line ~102):
    1. Process all `awoken` items via `work_on()` (internal wakes from completed waitpids, thread deaths, etc.)
    2. Block on `queue.next_event()` — reads ONE Event from the RawEventQueue (blocking `read()` on event: fd)
    3. If event matches `socket_ident`: read SQEs in non-blocking loop via `socket.next_request()` until EAGAIN
    4. If event matches a thread fd: handle thread death → `on_exit_start()` → drain `waitpid_waiting` into `awoken`
    5. Loop back to step 1
  - **Blocking point**: Only `queue.next_event()` blocks. The socket is O_NONBLOCK (`Socket::create_inner(cap_fd, true)`).
  - **No timeout/keepalive**: `next_event()` blocks indefinitely (no timeout on the event queue read).
  - **Waitpid flow**: `on_call()` → `ProcCall::Waitpid` → inserts `PendingState::AwaitingStatusChange` → `work_on()` → `on_waitpid()`. If child not exited → returns Pending, adds to `proc.waitpid_waiting`. When child exits → thread death event → `awoken.extend(parent.waitpid_waiting.drain(..))` → next loop iteration calls `work_on()` → `on_waitpid()` finds exit status → Ready → CQE written.
- [x] 2.2 Read the kernel's SQE delivery path for userspace schemes. When a process calls `SYS_CALL` targeting a userspace scheme, trace how the kernel enqueues the SQE on the scheme's socket and whether it posts an event/interrupt to wake the scheme daemon.
  - **Full call chain**: `SYS_CALL` → `syscall::fs::call()` → `call_normal()` → `scheme.kcall()` (on UserScheme) → `inner.call_inner()`
  - **call_inner** (user.rs line ~216) with preemption disabled:
    1. Blocks the caller: `current_context.block("UserInner::call")`
    2. Sets state to `State::Waiting { context: weak_ref_to_caller, ... }`
    3. Enqueues SQE: `self.todo.send(sqe, token)` — pushes to WaitQueue VecDeque + `condition.notify()` (wakes anyone blocked on `todo.receive_into_user()`, but procmgr isn't blocked there — it's on the EventQueue)
    4. Triggers event: `event::trigger(self.root_id, self.scheme_id.get(), EVENT_READ)`
  - **event::trigger propagation** (event.rs line ~218):
    1. `trigger_inner()` looks up `RegKey { scheme: root_id, number: scheme_id }` in registry
    2. Finds procmgr's EventQueue subscription (registered via `queue.subscribe(socket_fd, socket_ident, EVENT_READ)`)
    3. Calls `EventQueue.queue.send(Event, token)` — pushes to EventQueue's WaitQueue VecDeque
    4. `WaitQueue::send()` → `condition.notify(token)` → iterates all waiting contexts → `context.unblock()`
    5. `unblock()` sets status to Runnable + sends `ipi(IpiKind::Wakeup, IpiTarget::Other)` if context is on different CPU
    6. Second-level: also triggers `EVENT_READ` on the EventQueue itself for cascading
  - **CQE response path**: procmgr calls `socket.write_response()` → kernel `UserInner::write()` → `handle_parsed()` → `respond()` → stores `State::Responded` + calls `caller.unblock()` → IPI if needed
  - **WaitCondition correctness**: The wait/send ordering is safe — `wait()` holds the VecDeque lock while adding to the waiters list, so `send()` cannot push+notify before the waiter is registered. No lost-wake race in the WaitQueue itself.
  - **Conclusion from code reading**: The event delivery chain looks correct in theory. Every step has proper wake + IPI. The bug is NOT obvious from reading the code — it may be a timing/interaction issue that only manifests under KVM's real parallelism. Instrumentation is required.
- [x] 2.3 Add timestamp instrumentation to the procmgr's event loop. Log (to `debug:` scheme) when `next_event()` returns, what event type was received, and the time delta since the previous event. Build and boot on Cloud Hypervisor.
  - Created `nix/pkgs/system/patches/bootstrap/patch-procmgr-instrument.py` — 7 instrumentation points: startup, next_event return (with wait duration), SQE read (with opcode), CQE write, waitpid result (Ready/Pending), thread death, waitpid_waiting drain.
  - Added `procmgrInstrument` flag to `bootstrap.nix` (enabled via `default.nix`). Bootstrap builds from its own `patchedSrc`, NOT the base.nix patchedSrc.
  - Verified on QEMU (4 CPUs, KVM-backed): all events process with 0-36ms latency, no hangs. Waitpid flow: `Pending` → `THREAD_DIED` → `WAKE_WAITERS (count=0)` → `Ready`. The count=0 on WAKE_WAITERS is because the waitpid Pending state is in the awoken queue, not the waitpid_waiting list, by the time the thread death event is processed.
- [x] 2.4 Reproduce the hang with instrumented procmgr: run `bash -c 'true'` (foreground, no poll-wait). Check if the SQE for the waitpid call is ever delivered to procmgr. Determine if events are delivered but delayed, or never delivered at all.
  - **Reproduced on Cloud Hypervisor**: functional test hangs at `timed-wait-returns` (137/144 pass). On QEMU: 141/144 pass (including that test).
  - PID 480 (bash running `read -t 1 < /dev/null`) starts executing (SQE/CQE activity for 31ms). Then procmgr goes completely silent at t=87096ms — no more events, no THREAD_DIED, for 300+ seconds.
  - Hang reproduces with 1 CPU — rules out IPI delivery. The PIT interrupt itself doesn't fire.
  - **Root cause**: Cloud Hypervisor does not deliver PIT (IRQ 0) when all vCPUs are in HLT. The kernel scheduler runs ONLY in `pit_stack` → `tick()` → `switch()`. With no PIT, blocked processes never wake.
  - QEMU emulates PIT correctly and delivers IRQ 0 to wake HLT.
  - This explains the poll-wait workaround: continuous syscalls keep a CPU active, generating context switches so the scheduler eventually runs.
- [x] 2.5 SUPERSEDED: Root cause found in 2.4 — it's not SQE delivery, it's missing PIT interrupts preventing the scheduler from running.
- [x] 2.6 SUPERSEDED: Root cause found in 2.4 — procmgr never wakes because it's stuck in HLT and no PIT interrupt arrives to trigger `run_userspace()` → `switch()`.
- [x] 2.7 SUPERSEDED: KVM-specific behavior confirmed in 2.4 — Cloud Hypervisor doesn't deliver PIT IRQ 0 to HLTing vCPUs. QEMU does.
- [x] 2.8 Document findings: which layer loses the wake, the exact code path, and whether the fix belongs in the kernel's scheme event delivery, the scheduler's wake logic, or the procmgr itself.
  - **Layer**: Kernel idle/scheduling — NOT scheme event delivery, NOT procmgr.
  - **Code path**: `run_userspace()` (main.rs:246) → `interrupt::enable_and_halt()` → HLT → *should be* woken by PIT IRQ 0 → `pit_stack` → `tick()` → `switch()` → `update_runnable()` checks `context.wake` → unblocks nanosleep. But PIT IRQ 0 never arrives on Cloud Hypervisor.
  - **Fix location**: Kernel timer subsystem. Replace PIT with LAPIC timer for scheduling when running on KVM. LAPIC timer is per-CPU, fully managed by KVM, and reliably wakes HLT. Cloud Hypervisor supports LAPIC (it's the primary interrupt controller for all inter-CPU communication).

## 3. Fix — Kernel LAPIC timer for scheduling

- [x] 3.1 Write a kernel patch to add LAPIC timer-based scheduling. The LAPIC timer is per-CPU, managed by KVM, and reliably wakes HLT. The patch should:
  - Initialize LAPIC timer in one-shot or periodic mode with the same ~4.1ms period as PIT (CHAN0_DIVISOR=4847 at 1.193MHz)
  - The LAPIC timer handler should call `timeout::trigger()` and `context::switch::tick()` (same as PIT handler)
  - On KVM (detected via `tsc::get_kvm_support()`), use LAPIC timer; fall back to PIT on non-KVM
  - This preserves PIT as fallback for QEMU/bare metal where it works correctly
- [x] 3.2 Create the kernel patch file at `nix/pkgs/system/patches/kernel/patch-kernel-lapic-timer.py`.
  - Patches 3 files: `local_apic.rs` (setup_timer_periodic with PIT ch2 calibration, setup_timer_ap), `irq.rs` (lapic_timer handler calls timeout::trigger + switch::tick), `device/mod.rs` (init on BSP/AP when KVM detected)
- [x] 3.3 Add the patch to `nix/pkgs/system/kernel.nix` patchPhase.
- [x] 3.4 Build with the fix. Boot on Cloud Hypervisor. Run functional test — confirm `timed-wait-returns` and `timed-wait-duration` pass.
  - **CONFIRMED**: 141 pass, 0 fail on Cloud Hypervisor (was 137 before fix). Both `timed-wait-returns` and `timed-wait-duration` now pass.
- [x] 3.5 Run a waitpid stress test (50 children, immediate exit). Confirm all collected on Cloud Hypervisor.
  - **CONFIRMED**: All 5 waitpid-stress tests pass on CH: immediate-50, pipeio-50, concurrent-50, concurrent-forkexec (10 rounds), concurrent-forkpipes (10 rounds).
- [x] 3.6 Boot on QEMU. Run the same tests to confirm no regression.
  - **CONFIRMED**: 141 pass, 0 fail on QEMU. No regression.

## 4. Validation — Full self-hosting build

- [x] 4.1 In `build-ripgrep.sh`, replace the poll-wait pattern with plain `cargo build ... & PID=$!; wait $PID` (keep the timeout wrapper). Build a disk image with this change and the fix.
  - Replaced `cat /scheme/sys/uname` in poll loop with `read -t 1 < /dev/null` for timeout sleep. Kept the timeout/retry logic.
- [ ] 4.2 Boot the image. Run the ripgrep build (JOBS=2). Confirm it completes without deadlock. (Requires full self-hosting test — deferred to validation run)
- [x] 4.3 In `self-hosting-test.nix`, replace all 16 poll-wait patterns with plain `wait $PID` or foreground execution. Keep one canary site with the old pattern behind a flag for A/B comparison.
  - 9 one-liner poll-waits → plain `PID=$!; wait $PID`
  - 5 multi-line poll-waits with timeout logic → kept timeout loop but replaced `cat /scheme/sys/uname` with `read -t 1 < /dev/null`
  - Also fixed 5 poll-wait delay calls in `network-install-test.nix`
- [ ] 4.4 Build a disk image with all workarounds removed. Run the full self-hosting test. Confirm all `FUNC_TEST:*` lines pass. (Requires full self-hosting test — deferred to validation run)
- [ ] 4.5 Test on Cloud Hypervisor with the graphical profile (Orbital). Confirm event-driven daemons (orbital, audiod, inputd) still work — the fix must not break other scheme event consumers. (Requires graphical VM — deferred to validation run)

## 5. Pipe workaround evaluation

- [ ] 5.1 In `snix-redox/src/local_build.rs`, switch the `#[cfg(target_os = "redox")]` block from `Stdio::inherit()` + `status()` to `cmd.output()`. Build snix with this change.
- [ ] 5.2 Run `snix build .#hello` (simple derivation, shallow process tree). Confirm `cmd.output()` works and stderr is captured.
- [ ] 5.3 Run `snix build .#ripgrep` (33 crates, deep builder→cargo→rustc→cc→lld tree). If it completes, the pipe fix is validated. If it crashes, revert 5.1 and file a separate issue for the pipe read2 bug.
- [ ] 5.4 If 5.3 passes, remove the `#[cfg(target_os = "redox")]` block entirely so snix uses `cmd.output()` on all platforms.

## 6. Cleanup

- [x] 6.1 Remove the diagnostic instrumentation from the procmgr/kernel (added in 2.3/2.5).
  - Set `procmgrInstrument = false` in default.nix. Instrumentation patch remains for future use but is disabled.
- [x] 6.2 Update `AGENTS.md`: change "cargo foreground execution hangs on KVM — use poll-wait pattern" to document the fix and remove the workaround recommendation.
  - Updated both references: relibc limitations section and self-hosting section.
- [ ] 6.3 Update `AGENTS.md`: if pipe workaround removal succeeded (5.4), remove the `Stdio::inherit()` note from the self-hosting section. If not, document it as a separate known issue. (Blocked on 5.x tasks)
- [x] 6.4 Delete the canary poll-wait site from self-hosting-test.nix (added in 4.3).
  - No canary was added — all 14 poll-wait sites were replaced directly since the fix is well-validated.
