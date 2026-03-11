#!/usr/bin/env python3
"""
Patch cargo's job queue to emit periodic heartbeat diagnostics on Redox.

When CARGO_DIAG_LOG is set to a file path, cargo will append a status
line every ~5 seconds showing:
  - Active jobs (unit names + PIDs if available)
  - Number of pending jobs
  - Number of tokens held
  - Elapsed wall time

This helps diagnose JOBS>1 hangs by revealing which job cargo is
stuck waiting for, and whether it's blocked on child completion,
token acquisition, or something else.

The patch inserts into wait_for_events() which already has a 500ms
timeout loop. We count timeout iterations and emit a heartbeat
every 10th iteration (~5 seconds).

Target file: src/tools/cargo/src/cargo/core/compiler/job_queue/mod.rs
"""

import sys
import os


def patch_file(path):
    with open(path, "r") as f:
        content = f.read()

    original = content

    # 1. Add heartbeat counter and file handle to DrainState
    old_drain_state_end = """    per_package_future_incompat_reports: Vec<FutureIncompatReportPackage>,
}"""

    new_drain_state_end = """    per_package_future_incompat_reports: Vec<FutureIncompatReportPackage>,
    /// REDOX PATCH: heartbeat diagnostic counter (increments every 500ms timeout)
    heartbeat_counter: u32,
}"""

    if old_drain_state_end in content:
        content = content.replace(old_drain_state_end, new_drain_state_end)
        print("  Patched: added heartbeat_counter to DrainState")
    else:
        print(f"  WARNING: DrainState end pattern not found")
        return False

    # 2. Initialize heartbeat_counter in DrainState::new (the run() function)
    # Find where finished: 0 is initialized
    old_init = """            finished: 0,
            per_package_future_incompat_reports: Vec::new(),"""

    new_init = """            finished: 0,
            per_package_future_incompat_reports: Vec::new(),
            heartbeat_counter: 0,"""

    if old_init in content:
        content = content.replace(old_init, new_init)
        print("  Patched: initialized heartbeat_counter = 0")
    else:
        print(f"  WARNING: DrainState init pattern not found")
        return False

    # 3. Patch wait_for_events to emit heartbeat every ~5 seconds
    old_wait = """    fn wait_for_events(&mut self) -> Vec<Message> {
        // Drain all events at once to avoid displaying the progress bar
        // unnecessarily. If there's no events we actually block waiting for
        // an event, but we keep a "heartbeat" going to allow `record_cpu`
        // to run above to calculate CPU usage over time. To do this we
        // listen for a message with a timeout, and on timeout we run the
        // previous parts of the loop again.
        let mut events = self.messages.try_pop_all();
        if events.is_empty() {
            loop {
                self.tick_progress();
                self.tokens.truncate(self.active.len() - 1);
                match self.messages.pop(Duration::from_millis(500)) {
                    Some(message) => {
                        events.push(message);
                        break;
                    }
                    None => continue,
                }
            }
        }
        events
    }"""

    new_wait = """    fn wait_for_events(&mut self) -> Vec<Message> {
        // Drain all events at once to avoid displaying the progress bar
        // unnecessarily. If there's no events we actually block waiting for
        // an event, but we keep a "heartbeat" going to allow `record_cpu`
        // to run above to calculate CPU usage over time. To do this we
        // listen for a message with a timeout, and on timeout we run the
        // previous parts of the loop again.
        let mut events = self.messages.try_pop_all();
        if events.is_empty() {
            loop {
                self.tick_progress();
                self.tokens.truncate(self.active.len() - 1);
                match self.messages.pop(Duration::from_millis(500)) {
                    Some(message) => {
                        events.push(message);
                        break;
                    }
                    None => {
                        // REDOX PATCH: emit heartbeat diagnostic every ~5s
                        self.heartbeat_counter += 1;
                        if self.heartbeat_counter % 10 == 0 {
                            self.emit_heartbeat_diagnostic();
                        }
                        continue;
                    }
                }
            }
        }
        events
    }

    /// REDOX PATCH: Write diagnostic heartbeat to CARGO_DIAG_LOG file.
    fn emit_heartbeat_diagnostic(&self) {
        use std::io::Write;
        let log_path = match std::env::var("CARGO_DIAG_LOG") {
            Ok(p) if !p.is_empty() => p,
            _ => return,
        };
        let mut f = match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
        {
            Ok(f) => f,
            Err(_) => return,
        };
        let elapsed_secs = self.heartbeat_counter as f64 * 0.5;
        let active_list: Vec<String> = self
            .active
            .iter()
            .map(|(id, unit)| format!("{}(id={})", unit.pkg.name(), id.0))
            .collect();
        let _ = writeln!(
            f,
            "[heartbeat t={:.0}s] active={} pending={} tokens={} finished={}/{} jobs=[{}]",
            elapsed_secs,
            self.active.len(),
            self.pending_queue.len(),
            self.tokens.len(),
            self.finished,
            self.total_units,
            active_list.join(", "),
        );
    }"""

    if old_wait in content:
        content = content.replace(old_wait, new_wait)
        print("  Patched: wait_for_events with heartbeat diagnostic")
    else:
        print(f"  WARNING: wait_for_events pattern not found")
        return False

    if content != original:
        with open(path, "w") as f:
            f.write(content)
        return True
    return False


def main():
    if len(sys.argv) < 2:
        print("Usage: patch-cargo-heartbeat.py <rust-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]
    target = os.path.join(
        src_dir,
        "src",
        "tools",
        "cargo",
        "src",
        "cargo",
        "core",
        "compiler",
        "job_queue",
        "mod.rs",
    )

    if not os.path.exists(target):
        print(f"ERROR: {target} not found")
        sys.exit(1)

    print(f"Patching {target}...")
    if patch_file(target):
        print("Done! cargo will emit heartbeat diagnostics when CARGO_DIAG_LOG is set.")
    else:
        print("WARNING: Patch failed!")
        sys.exit(1)


if __name__ == "__main__":
    main()
