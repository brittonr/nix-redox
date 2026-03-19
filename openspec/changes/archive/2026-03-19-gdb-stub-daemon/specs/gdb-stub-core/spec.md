## ADDED Requirements

### Requirement: Attach to process by PID
The gdbstub SHALL attach to a target process by opening `proc:<pid>/trace`, `proc:<pid>/regs/int`, `proc:<pid>/regs/float`, and `proc:<pid>/mem`. The target process SHALL be stopped upon attachment.

#### Scenario: Attach to running process
- **WHEN** `gdbstub <pid>` is run where `<pid>` is a running process
- **THEN** gdbstub opens the proc: scheme files and the target process is stopped

#### Scenario: Attach to nonexistent process
- **WHEN** `gdbstub <pid>` is run where `<pid>` does not exist
- **THEN** gdbstub prints an error and exits with nonzero status

### Requirement: Launch and debug new process
The gdbstub SHALL support launching a new process with `--exec <path> [args...]`. It SHALL fork, SIGSTOP the child, exec the binary, then attach as tracer — the same pattern strace-redox uses.

#### Scenario: Launch with --exec
- **WHEN** `gdbstub --exec /bin/hello` is run
- **THEN** gdbstub spawns `/bin/hello`, stops it before first instruction, attaches, and waits for GDB connection

### Requirement: TCP listener for GDB connection
The gdbstub SHALL listen on a TCP port (default 1234) for a GDB remote connection. It SHALL accept one client at a time.

#### Scenario: GDB connects
- **WHEN** GDB runs `target remote <ip>:1234`
- **THEN** gdbstub accepts the connection and begins RSP communication

#### Scenario: Custom port
- **WHEN** `gdbstub <pid> --port 9999` is run
- **THEN** gdbstub listens on port 9999

### Requirement: Read registers (g packet)
The gdbstub SHALL respond to the RSP `g` command by reading `proc:<pid>/regs/int` and returning the x86_64 register file in GDB's expected order (rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, r8-r15, rip, eflags, cs, ss, ds, es, fs, gs) as hex-encoded bytes.

#### Scenario: Read integer registers
- **WHEN** GDB sends `g`
- **THEN** gdbstub reads IntRegisters from proc: and returns hex-encoded register values

### Requirement: Write registers (G packet)
The gdbstub SHALL respond to the RSP `G` command by parsing the hex register data and writing to `proc:<pid>/regs/int`.

#### Scenario: Write integer registers
- **WHEN** GDB sends `G<hex data>`
- **THEN** gdbstub writes the parsed registers to proc: and returns `OK`

### Requirement: Read memory (m packet)
The gdbstub SHALL respond to `m addr,length` by seeking to addr in `proc:<pid>/mem` and reading length bytes, returning hex-encoded data.

#### Scenario: Read valid memory
- **WHEN** GDB sends `m7fff0000,100`
- **THEN** gdbstub reads 256 bytes from the target's memory and returns hex data

#### Scenario: Read unmapped memory
- **WHEN** GDB sends `m` for an unmapped address
- **THEN** gdbstub returns error packet `E14`

### Requirement: Write memory (M packet)
The gdbstub SHALL respond to `M addr,length:XX...` by seeking to addr in `proc:<pid>/mem` and writing the decoded bytes.

#### Scenario: Write memory
- **WHEN** GDB sends `M7fff0000,4:deadbeef`
- **THEN** gdbstub writes the bytes and returns `OK`

### Requirement: Continue execution (c packet)
The gdbstub SHALL respond to `c` by setting the ptrace breakpoint to wait for the next stop event and resuming the tracee.

#### Scenario: Continue and hit breakpoint
- **WHEN** GDB sends `c` and the target hits a software breakpoint
- **THEN** gdbstub receives PTRACE_STOP_BREAKPOINT event and sends stop reply `S05` (SIGTRAP)

### Requirement: Single step (s packet)
The gdbstub SHALL respond to `s` by writing PTRACE_STOP_SINGLESTEP to the trace file and waiting for the tracee to execute one instruction.

#### Scenario: Single step
- **WHEN** GDB sends `s`
- **THEN** gdbstub single-steps the target and sends stop reply `S05`

### Requirement: Software breakpoints (Z0/z0 packets)
The gdbstub SHALL support inserting software breakpoints via `Z0,addr,kind` by reading the original byte at addr, writing `0xCC` (int3), and storing the original for restoration. Removal via `z0,addr,kind` SHALL restore the original byte.

#### Scenario: Set and hit breakpoint
- **WHEN** GDB sends `Z0,401000,1` then `c`
- **THEN** gdbstub patches int3 at 0x401000, the target hits it, gdbstub reports `S05`

#### Scenario: Remove breakpoint
- **WHEN** GDB sends `z0,401000,1`
- **THEN** gdbstub restores the original byte at 0x401000 and returns `OK`

### Requirement: Stop reason query (? packet)
The gdbstub SHALL respond to `?` with the current stop reason. If the target is stopped at a breakpoint, return `S05`. If stopped by signal, return `S<signum>`.

#### Scenario: Query stop reason
- **WHEN** GDB sends `?` after connection
- **THEN** gdbstub returns the stop reason for the attached process

### Requirement: Unsupported commands return empty
The gdbstub SHALL return an empty response for any RSP command it does not support, per the GDB RSP specification.

#### Scenario: Unknown command
- **WHEN** GDB sends an unsupported command like `qTStatus`
- **THEN** gdbstub returns empty packet `$#00`
