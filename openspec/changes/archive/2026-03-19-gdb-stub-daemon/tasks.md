## 1. Crate scaffold

- [x] 1.1 Create `src/gdbstub/Cargo.toml` with dependencies: gdb-protocol (path or git), redox_syscall, libredox
- [x] 1.2 Create `src/gdbstub/src/main.rs` with argument parsing (pid, --exec, --port)
- [x] 1.3 Generate `Cargo.lock` for the crate

## 2. Process attachment

- [x] 2.1 Implement `attach(pid)` — open `proc:<pid>/trace`, `proc:<pid>/regs/int`, `proc:<pid>/regs/float`, `proc:<pid>/mem`
- [x] 2.2 Implement `launch(path, args)` — fork, SIGSTOP child, exec, attach (strace-redox pattern)
- [x] 2.3 Handle attach errors (ENOENT, EPERM) with clear error messages

## 3. Register mapping

- [x] 3.1 Define GDB x86_64 register file layout (order, sizes) as a constant table
- [x] 3.2 Implement `read_registers()` — read IntRegisters from proc:, serialize to GDB hex format in correct order
- [x] 3.3 Implement `write_registers(hex)` — parse GDB hex data, write IntRegisters to proc:
- [x] 3.4 Implement float register read for `p` packet (individual register read)

## 4. Memory access

- [x] 4.1 Implement `read_memory(addr, len)` — seek + read from `proc:<pid>/mem`, return hex
- [x] 4.2 Implement `write_memory(addr, data)` — seek + write to `proc:<pid>/mem`
- [x] 4.3 Handle unmapped page errors gracefully (return E14, don't crash)

## 5. Execution control

- [x] 5.1 Implement `continue_execution()` — write STOP_ALL flags to trace file, wait for ptrace event
- [x] 5.2 Implement `single_step()` — write STOP_SINGLESTEP flag, wait for one event
- [x] 5.3 Map ptrace events to GDB stop replies (STOP_BREAKPOINT → S05, STOP_SIGNAL → S<num>, STOP_EXIT → W<status>)

## 6. Software breakpoints

- [x] 6.1 Implement breakpoint table (HashMap<u64, u8> mapping address → original byte)
- [x] 6.2 Implement `insert_breakpoint(addr)` — read original byte, write 0xCC, store in table
- [x] 6.3 Implement `remove_breakpoint(addr)` — restore original byte from table
- [x] 6.4 On breakpoint hit, rewind RIP by 1 (int3 increments it past the 0xCC)

## 7. RSP command dispatch

- [x] 7.1 Implement main packet dispatch loop using gdb-protocol's GdbServer::next_packet()
- [x] 7.2 Handle `?` — return current stop reason
- [x] 7.3 Handle `g`/`G` — read/write registers
- [x] 7.4 Handle `m`/`M` — read/write memory
- [x] 7.5 Handle `c` — continue
- [x] 7.6 Handle `s` — single step
- [x] 7.7 Handle `Z0`/`z0` — insert/remove software breakpoint
- [x] 7.8 Handle `qSupported` — report supported features (PacketSize, no-multiprocess)
- [x] 7.9 Handle `Hg`/`Hc` — thread select (map to PID, return OK)
- [x] 7.10 Handle `k` — kill target and exit
- [x] 7.11 Return empty packet for all unrecognized commands

## 8. Nix packaging

- [x] 8.1 Create `nix/pkgs/userspace/gdbstub.nix` — cross-compile with mkUserspace
- [x] 8.2 Add gdbstub to `nix/flake-modules/packages.nix`
- [x] 8.3 Add `gdbstub = self'.packages.gdbstub or null;` to extraPkgs in `nix/flake-modules/system.nix`
- [x] 8.4 Add `opt "gdbstub"` to development profile alongside strace
- [x] 8.5 Verify `nix build .#gdbstub` produces `bin/gdbstub` for x86_64-unknown-redox

## 9. Integration testing

- [x] 9.1 Boot development profile VM with gdbstub in the image
- [x] 9.2 proc: scheme access restored — the blocker was `proc:` missing from user session namespace (login's `mkns()` scheme list). Fixed via `/etc/login_schemes.toml`. The kernel trace/mem handles and procmgr forwarding work: `cat proc:PID/regs/int` returns data, `cat proc:PID/trace` blocks on events.
- [x] 9.3 gdbstub --selftest validates proc: operations end-to-end
  - ✅ fork+exec child, open trace/regs/mem handles
  - ✅ register read (valid RIP, RSP, RAX)
  - ✅ memory read at RIP, RSP, page-aligned (all return valid data)
  - ❌ single step causes kernel panic in `ptrace::breakpoint_callback` → `VecDeque::grow`
  - Networking blocker: QEMU user-mode NAT requires DHCP; Redox auto-DHCP hardcodes `eth0` but Redox uses PCI-path interface names. GDB host→guest TCP connection blocked by this.
- [ ] 9.4 Verify single step, continue, breakpoint — blocked by kernel ptrace breakpoint_callback crash

### Bugs found during testing
1. **proc:mem offset bug (FIXED)**: Memory handle's kreadoff used an internal AtomicU64 offset (always 0) instead of the file descriptor offset from lseek(). All memory reads returned EFAULT at address 0. Fix: use the `offset` parameter from kreadoff/kwriteoff.
2. **ptrace breakpoint_callback crash (OPEN)**: Resuming a SIGSTOP'd traced process and triggering ptrace events causes a kernel panic in `VecDeque::grow` inside `ptrace::breakpoint_callback`. The ptrace event queue push path hits an allocation failure or invalid state. Needs kernel-level investigation.
3. **DHCP interface naming (KNOWN)**: `dhcpd -v eth0` fails because Redox uses PCI-path interface names (e.g., `pci-0000-00-04.0_e1000`), not `eth0`. The `netcfg` scheme is also missing from user session namespace.
