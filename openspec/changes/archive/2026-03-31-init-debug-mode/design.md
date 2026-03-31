## Context

The Redox init binary (`base/init/src/main.rs`) reads two environment variables at startup:

- `INIT_LOG_LEVEL` — defaults to `"INFO"`. When `"DEBUG"` or `"TRACE"`, `InitConfig.log_debug` is true, causing init to log each script command, service spawn (with description and cmd), and target reached.
- `INIT_SKIP` — comma-separated list of command names. Services whose `cmd` matches a name in this list are skipped with a log message.

These are read in `InitConfig::new()` before any units are processed — before even `00_runtime.target`.

### How env vars reach init today

The chain is:

1. **Bootloader** (`bootloader/src/main.rs`) allocates a 64KB env buffer and writes hardware-probed key=value pairs: `RSDP_ADDR`, `REDOXFS_UUID`, `REDOXFS_BLOCK`, `FRAMEBUFFER_*`, etc. It also offers an interactive editor (press `e` at the resolution screen) to manually add/edit env vars before boot.
2. **Kernel** stores the env block in `Bootstrap.env`, serves it via `sys:env`.
3. **Bootstrap** (`base/bootstrap/src/exec.rs`) reads `sys:env`, filters out `INITFS_*` vars, then hardcodes two additional vars:
   ```rust
   envs.push(b"RUST_BACKTRACE=1");
   envs.push(b"LD_LIBRARY_PATH=/scheme/initfs/lib");
   ```
   Then calls `fexec_impl()` to exec init with this env.
4. **Init** reads `INIT_LOG_LEVEL` and `INIT_SKIP` from its inherited process environment.

There is currently no declarative way to set `INIT_LOG_LEVEL` or `INIT_SKIP`. The only method is the bootloader's interactive editor, which requires manual keypresses at every boot.

## Goals / Non-Goals

**Goals:**
- Expose `boot.initDebug` and `boot.initSkip` as Nix module options
- Inject the corresponding env vars into init's process environment at boot
- No changes to the init binary

**Non-Goals:**
- Adding new log levels beyond DEBUG (init only distinguishes DEBUG/TRACE from everything else)
- Modifying the bootloader
- Runtime toggling of debug mode after boot

## Decisions

**1. Injection point: bootstrap, not init**

Init reads env vars in `main()` before processing any unit files. Unit-file-based injection is impossible. Patching init to read a config file would work but adds complexity to a binary we don't own.

Bootstrap already hardcodes `RUST_BACKTRACE=1` — the exact same pattern we need. The cleanest approach is to patch bootstrap to read an optional file from the initfs and add those vars to the `envs` vector before `fexec`.

Bootstrap runs as `no_std` with a custom allocator but already does `syscall::openat` against kernel schemes. Reading a small file from initfs is straightforward — initfs is already mounted as a scheme at that point (`/scheme/initfs`).

**2. Marker file location and format**

`/scheme/initfs/etc/init.env` — a simple `KEY=VALUE\n` file. Bootstrap reads it via `syscall::openat` on the initfs scheme fd, splits on newlines, and pushes each line to the `envs` vector (same `&[u8]` slices as the existing hardcoded vars).

The file is only present in the initfs when debug options are enabled. When the file doesn't exist, the `openat` fails silently and bootstrap proceeds unchanged.

**3. Why not patch the bootloader env block?**

The bootloader builds the env buffer at runtime from hardware probing. There's no mechanism to inject static vars at build time — the env is constructed procedurally in `main()` and passed to the kernel via `KernelArgs.env_base`. We'd need to modify the bootloader source, which is a separate repo and cross-compiled for UEFI target. Patching bootstrap (which is already part of the base package we build) is far simpler.

**4. Why not read from a rootfs config file?**

Init reads its config vars before any rootfs is mounted. The entire initfs phase (zerod, randd, drivers, redoxfs mount) runs first. By the time rootfs is available, `InitConfig::new()` has already run. The initfs is the only filesystem available when bootstrap execs init.

**5. Option naming**

Follow existing `/boot` patterns (alongside `kernelSyscallDebug`, `rustBacktrace`):
- `boot.initDebug` — `t.bool`, default `false`
- `boot.initSkip` — `t.listOf t.string`, default `[]`

## Risks / Trade-offs

- **[Risk] Bootstrap patch diverges from upstream** → The patch is ~15 lines of `no_std` Rust, reading one optional file. If the file doesn't exist, zero behavior change. Same risk profile as the existing `RUST_BACKTRACE=1` hardcoding that upstream already does.
- **[Risk] Bootstrap's `no_std` allocator limits** → The env file will be tiny (under 100 bytes). Bootstrap already allocates a 4KB buffer for the kernel env. We use a fixed-size stack buffer for the file read, same as the existing `env_bytes` pattern.
- **[Trade-off] Bootstrap patch vs init patch** → Bootstrap patch means no init changes and the env vars appear in init's process environment identically to bootloader-provided vars. Init can't distinguish them from hardware env vars. This is exactly the right semantics.
