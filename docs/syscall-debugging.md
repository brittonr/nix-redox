# Syscall Debugging on Redox OS

Two approaches for tracing system calls: userspace `strace` and kernel-level tracing.

## 1. strace-redox (Userspace)

Trace syscalls for a single process from within Redox. No kernel rebuild needed.

### Setup

Included in `development.nix` and `dev-workstation` profiles by default. If building a custom profile:

```nix
"/environment".systemPackages = [ pkgs.strace-redox ];
```

### Usage

```sh
strace /bin/ls
strace -p 42        # attach to running PID
strace cargo build   # trace a build
```

Output goes to stderr. Useful for debugging individual programs.

### When to use

- Quick debugging of a specific program
- Checking what files/schemes a program opens
- Understanding why a program hangs (which syscall it's stuck on)

## 2. Kernel syscall_debug (Kernel-Level)

Compile tracing into the kernel. ALL matching syscalls are printed to the serial console. Higher overhead but catches everything, including daemons and scheme interactions that strace can't attach to.

### Quick enable via module option

```nix
# In your profile or configuration module:
{ pkgs, lib }: {
  "/boot".kernelSyscallDebug = true;
}
```

This:
- Swaps in a kernel built with the `syscall_debug` feature
- Removes the upstream `false &&` guard in `debug.rs`
- Traces ALL processes (filtered only by the standard noise exclusions: `clock_gettime`, `yield`, `futex`, stdout/stderr writes)

### Building the debug kernel standalone

```sh
nix build .#kernelSyscallDebug
```

### Custom process filtering

For tracing only specific programs, use the `mkKernelSyscallDebug` builder:

```nix
# In your flake or configuration:
"/boot".kernel = self'.legacyPackages.mkKernelSyscallDebug {
  debugProcesses = [ "cargo" "rustc" ];
};
```

Process names are matched with `contains()` — `"cargo"` matches `/bin/cargo`, `/usr/bin/cargo`, etc. Be careful with short names like `"ls"` which match `"false"` too. Use longer paths like `"/bin/ls"` when needed.

### Reading the output

Kernel syscall traces go to serial console output:

```sh
# Cloud Hypervisor: output appears in the terminal
nix run .#run-redox-default

# QEMU: capture with tee
nix run .#runQemu 2>&1 | tee syscall-trace.log

# Filter for a specific program
grep "cargo" syscall-trace.log
```

Each syscall prints two lines — entry and exit with the return value:

```
/bin/cargo (*42*): SYS_OPEN "/Cargo.toml" O_RDONLY
/bin/cargo (*42*): -> Ok(3)
```

### What gets filtered by default

Even with tracing on, these high-frequency syscalls are suppressed:
- `SYS_CLOCK_GETTIME` — called constantly by Rust's `Instant::now()`
- `SYS_YIELD` — scheduler yield
- `SYS_FUTEX` — mutex/condvar operations
- `SYS_WRITE`/`SYS_FSYNC` to fd 1 or 2 — stdout/stderr (prevents recursion)

To trace these too, you'd need to edit `src/syscall/debug.rs` in the kernel source directly.

## Comparison

| Feature | strace-redox | kernel syscall_debug |
|---------|-------------|---------------------|
| Requires kernel rebuild | No | Yes |
| Attach to running process | Yes | No (compile-time filter) |
| Traces scheme daemons | Only if strace wraps them | Yes, all processes |
| Traces early boot | No | Yes |
| Output destination | stderr of strace | Serial console |
| Performance impact | Moderate (ptrace) | Heavy (every syscall) |
| Multiple processes | One at a time | All matching processes |

## Recipes

### Debug a cargo build that hangs

```sh
# Userspace approach (from Redox shell):
strace cargo build 2> /tmp/strace.log

# Kernel approach (from host):
# 1. Build with syscall debug for cargo + rustc
"/boot".kernelSyscallDebug = true;
# 2. Boot and run, capture serial output
nix run .#run-redox-default 2>&1 | tee build-trace.log
```

### Debug a scheme daemon

Scheme daemons run in the background — strace can't easily wrap them. Use kernel tracing:

```nix
"/boot".kernel = self'.legacyPackages.mkKernelSyscallDebug {
  debugProcesses = [ "stored" "profiled" ];
};
```

### Debug early boot issues

Only kernel tracing works here — strace isn't available until userspace is up:

```nix
"/boot".kernelSyscallDebug = true;  # traces init, logd, ipcd, ptyd, ...
```
