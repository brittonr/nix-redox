## ADDED Requirements

### Requirement: Open trace handle via proc scheme
The kernel proc: scheme SHALL accept the path `trace` when opening `proc:<pid>/trace`, creating a ptrace Session attached to the target process. Only one trace session per process SHALL be allowed.

#### Scenario: Open trace for a running process
- **WHEN** userspace opens `proc:<pid>/trace` with read+write
- **THEN** the kernel creates a ptrace Session, stores it on the target Context, and returns a file descriptor

#### Scenario: Open trace when already traced
- **WHEN** userspace opens `proc:<pid>/trace` for a process that already has a tracer
- **THEN** the kernel returns EBUSY

### Requirement: Write breakpoint flags to trace handle
The kernel SHALL accept writes of `PtraceFlags` (u64 little-endian) to the trace handle, setting the breakpoint mask on the ptrace Session.

#### Scenario: Set breakpoint flags
- **WHEN** userspace writes PTRACE_STOP_SINGLESTEP flags to the trace fd
- **THEN** the kernel sets the session breakpoint and the tracee stops on next single-step

### Requirement: Read ptrace events from trace handle
The kernel SHALL return PtraceEvent structs when reading from the trace handle. Reads SHALL block until an event is available.

#### Scenario: Read after breakpoint hit
- **WHEN** the tracee hits a breakpoint and userspace reads from the trace fd
- **THEN** the kernel returns a PtraceEvent with cause=PTRACE_STOP_BREAKPOINT

#### Scenario: Read with no events pending
- **WHEN** userspace reads from the trace fd with no pending events
- **THEN** the read blocks until an event arrives

### Requirement: Context switch loads ptrace session
The kernel context switch code SHALL load the incoming context's ptrace session Weak reference into the per-CPU `ptrace_session` field, so that `ptrace::Session::current()` returns the correct session for breakpoint callbacks.

#### Scenario: Traced process runs and hits syscall
- **WHEN** a traced process enters a syscall
- **THEN** `ptrace::breakpoint_callback(PTRACE_STOP_PRE_SYSCALL)` finds the session and delivers the event to the tracer

### Requirement: Close trace handle cleans up
The kernel SHALL close the ptrace session and clear the Context's session reference when the trace handle is closed. The tracee SHALL resume normal execution.

#### Scenario: Tracer closes trace fd
- **WHEN** the tracer closes the trace file descriptor
- **THEN** the tracee resumes and ptrace callbacks become no-ops for that process
