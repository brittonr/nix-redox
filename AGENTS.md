# AGENTS.md — Permanent Build Knowledge

Hard-won lessons from building RedoxOS with Nix. Read before making changes.

## Reference Repos

Upstream Redox source cloned in `~/git/pi-repos/` for code-level reference:

| Repo | When to use |
|------|-------------|
| `redox-os--kernel` | Syscall implementation details, scheduler behavior, memory management, arch-specific code |
| `redox-os--syscall` | Syscall numbers, flags, data structures, scheme v2 interface |
| `redox-os--acid` | Existing test patterns, regression test examples, what's already covered |
| `redox-os--book` | Redox concepts, architecture docs (also mirrored in `docs/redox-book/`) |
| `redox-os--benchmarks` | Performance benchmark scripts, recorded baseline numbers |
| `redox-os--pkgutils` | Package manager internals (pkg-lib, pkgar format) |
| `redox-os--redoxfs` | Filesystem scheme implementation, handle management, mmap |
| `redox-os--base` | Base system repo — core daemons (init, bootstrap, ptyd, ipcd, logd, netstack, ramfs, randd, zerod, audiod) + `drivers/` (acpid, pcid, storage, graphics, input, audio, net, USB, virtio-core) + initfs, daemon lib, config |
| `asterinas--asterinas` | Asterinas OS — Rust-based OS framework with framekernel architecture, OSTD hardware abstraction, OSDK build tooling |

## Redox OS Platform

### Ion Shell (NOT POSIX)
- Variables: `let var = "value"` (not `var="value"`)
- Arrays: `@array` sigil (strings use `$var`)
- Control flow ends with `end` (not `fi`, `done`)
- `else if` (not `elif`), no `then` keyword
- Redirect stderr: `^>` (not `2>`)
- Export: `export VAR value` (not `export VAR=value`); `export VAR` alone fails if VAR doesn't exist
- `$()` command substitution crashes on empty output: `let var = $(grep ...)` → "Variable '' does not exist"
- `command not found` in Ion kills the entire script — no error recovery, subsequent lines never execute
- Setting PATH: `let PATH = "/nix/system/profile/bin:/bin:/usr/bin"` then `export PATH` — `export PATH /value` fails if PATH doesn't exist yet
- Test scripts MUST set PATH at the top — startup.sh runs before profile.ion is sourced, so `/nix/system/profile/bin` may not be in PATH
- Wrap diagnostic sections in `/nix/system/profile/bin/bash -c '...'` to isolate failures from Ion — one bad command in Ion kills the whole script
- `@()` process expansion unreliable with pipes and `matches`
- No heredoc (`<< EOF`) support
- Single quotes prevent all expansion — safe for Nix expressions with `{}[]()`
- Apostrophes in `bash -c '...'` blocks break Ion's quote parser
- `$?` unreliable between external commands — emit PASS/FAIL directly from bash blocks
- `let HOME = ...` fails — HOME is a protected variable in Ion; use bash for scripts that need to set HOME
- `echo $var | grep` pipes fail silently — use Ion-native `test` or `is` for comparisons

### Available Commands
**In uutils**: cat, cp, df, du, echo, head, ls, mkdir, mv, pwd, rm, sort, touch, uniq, wc
**In extrautils**: grep, less, tar
**NOT available**: dd, tail, sed, awk, cut, find, chmod (use full path `/nix/system/profile/bin/chmod`)
- `grep` has no `\|` alternation or `-E` extended regex — use separate grep calls
- `sleep` is compiled in uutils — uses nanosleep syscall, works correctly
- nanosleep syscall works correctly (kernel SYS_NANOSLEEP + scheduler wake verified 2026-03-11)

### Scheme System
- Scheme daemons CANNOT do `file:` I/O through the namespace manager (initnsmgr) inside the event loop
- Root cause: initnsmgr is SINGLE-THREADED — it processes one request at a time. If initnsmgr forwards to your scheme (blocking), and your scheme tries to open a file (which goes through initnsmgr), you get a circular deadlock: initnsmgr→proxy→initnsmgr
- This affects ALL threads in the process, not just the event loop thread — `File::open()` always routes through `SYS_OPENAT(current_namespace_fd(), ...)` which goes to initnsmgr
- FIX: Pre-open `/` before starting the proxy to get a direct redoxfs fd. Use `SYS_OPENAT(root_fd, path, ...)` for real file I/O — this bypasses initnsmgr entirely, routing directly to redoxfs through the kernel
- initnsmgr source: `base-src/bootstrap/src/initnsmgr.rs` — the event loop calls `handle_sync()` then `write_response()` sequentially, no concurrency
- Use `.control` write interface for notifications (write+close = mutation cycle)
- `FileIoWorker` background thread doesn't help for file: schemes — use the pre-opened root fd pattern instead
- `std::fs::canonicalize()` returns `file:/path` on Redox — strip prefix defensively
- `debug:` scheme supports reads via EVENT_READ, but simple blocking reads from Ion's `read` don't work
- `getty` works on `debug:` because it uses event-driven non-blocking I/O with event queues
- "Scheme 'file' not found" warnings during early boot are normal (before redoxfs mounts rootfs)

### Build Sandbox
- snix builds use scheme-level namespace sandboxing (mkns/setns)
- Builder runs in a restricted namespace with only essential schemes (file, memory, pipe, rand, null, zero, proc, sys, time, debug, shm)
- file: is the REAL redoxfs — builder has full filesystem access but can't reach display:, disk:, irq:, audio:, etc.
- FOD (fixed-output derivation) builds additionally get `net` scheme

### Build Sandbox — Per-Path Proxy (DISABLED)
- Per-path proxy code is preserved in build_proxy module but disabled in local_build.rs
- **Root cause of deadlock**: proxy thread does `raw_openat(root_fd, ...)` to redoxfs, but the kernel blocks ALL file: I/O from a process that owns a scheme socket — even via pre-opened fds that bypass initnsmgr
- Symptom: snix build hangs indefinitely on the first builder exec (bash never starts)
- The proxy STARTS correctly (scheme registered, event loop running), but the first openat request deadlocks when the proxy tries to forward it to redoxfs
- `setns()` correctly updates DYNAMIC_PROC_INFO.ns_fd (relibc's `redox_setns_v0` replaces it); exec correctly passes ns_fd through auxv (AT_REDOX_NS_FD=43)
- The exec mechanism is NOT the issue — the deadlock is in the kernel's scheme I/O blocking policy
- Fix requires kernel change: allow SYS_OPENAT on pre-opened fds (different scheme instance) from scheme-socket-owning processes
- Proxy code preserved: AllowList, BuildFsProxy, handler, lifecycle, allow_list builder, setup_proxy_namespace
- Proxy was designed with: mkdir_p_via_root_fd, O_APPEND seek-to-end, getdents filtering, /dev/* pre-opened fds

### relibc Limitations
- `nanosleep()` works correctly (SYS_NANOSLEEP syscall 162, kernel context.wake + scheduler verified)
- `Instant::now()` advances via clock_gettime(CLOCK_MONOTONIC) reading HPET/PIT hardware
- `poll()` unreliable for pipe multiplexing — use thread-based read2 instead
- `Mutex` is non-reentrant — child inherits locked state after `fork()` → deadlock
- `abort()` uses `ud2` instruction → opaque kernel register dump. Patched to `_exit(134)`.
- `flock()` is a no-op in upstream relibc (returns Ok(()) immediately)
- Foreground process execution fixed — LAPIC timer patch (`patch-kernel-lapic-timer.py`) provides reliable scheduling on KVM when all CPUs are in HLT
- `fcntl` F_SETLK/F_SETLKW patched to no-op (return Ok(0))
- `exec()` env propagation fixed for DSO-linked binaries (DSO environ patches)
- `execvpe()` added to relibc; DSO environ fix (patch-relibc-environ-dso-init.py) broadcasts environ to __relibc_init_environ after relibc_start_v1
- `mbstate_t` is empty struct `{}` — `{0}` initialization invalid in C++, use `= {}`
- Missing POSIX functions: `*at` variants (openat, unlinkat, utimensat), `strtof_l` family, `REG_STARTEND`
- `S_IRWXU` etc. are `i32` not `u32` — needs cast
- Open flags differ: `O_RDONLY=0x10000`, `O_CREAT=0x02000000` — translate for FUSE

### Unwind Stubs (stub-libs.nix)
- Stub archives (libgcc.a, libgcc_eh.a, libunwind.a) MUST use per-function .o files
- Old single-file approach: ALL stubs in one unwind_stubs.o → linking ANY _Unwind symbol drags in ALL stubs including _Unwind_RaiseException
- _Unwind_RaiseException returning 0 → "failed to initiate panic, error 0" → abort in panic=unwind binaries (rustc)
- Per-function .o files: linker pulls only the stubs actually referenced — _Unwind_RaiseException stays in archive for panic=abort packages
- Real libunwind (from libc++) was tried for panic=unwind but the DWARF stack walker overflows rustc's already-deep LLVM init stack
- abort() stubs were tried but break DSO init paths that touch _Unwind_Resume during C++ landing pad cleanup
- Return-0 stubs are the working compromise: panic=abort never calls them, panic=unwind gets "error 0" then clean abort
- On-image stubs (redox-sysroot.nix) must match the same per-function pattern
- `RAYON_NUM_THREADS=4` must be set in self-hosting profiles — Rayon/rustc call available_parallelism() which panics (sysconf _SC_NPROCESSORS_ONLN unimplemented)

### Dynamic Linking — .symtab Fallback for LOCAL Symbols
- Pre-built DSOs (librustc_driver.so) have `__relibc_init_*` as LOCAL in `.symtab` due to Rust `local: *;` version scripts
- ld_so's `get_sym()` only searches `.dynsym` hash table — misses LOCAL symbols entirely
- Fix: `patch-relibc-symtab-fallback.py` scans `.symtab` during DSO construction via `FileHeader::sections()` + `symbol_table_by_index()`
- Stores addresses in `LocalInitSyms` struct on DSO; `run_init` uses them as fallback when `get_sym` returns None
- Covers all 6 init symbols: `environ`, `proc_fd`, `ns_fd`, `cwd_ptr`, `cwd_len`, `cwd_fd`
- The `object` crate with `["elf", "read_core"]` features does NOT have `SectionTable::symbol_table()` — must iterate sections manually to find `SHT_SYMTAB`, then call `symbol_table_by_index()`
- `Object` trait's `symbol_table()` returns `Option<ElfSymbolTable>` (not `Result`), but `ElfSymbolTable` methods differ from raw `SymbolTable` — use raw `FileHeader` API instead
- `current_namespace_fd()` returns `Result<usize>` (not plain `usize`) after `patch-relibc-ns-fd.patch`
- `std::env::set_var` is unsafe in Rust edition 2024

### Dynamic Linking
- Each DSO gets its own copy of relibc statics (CWD, ns_fd, proc_fd, environ)
- `ld_so run_init()` injects ns_fd, proc_fd, CWD, environ into DSOs via `__relibc_init_*` symbols
- Version scripts must include `__relibc_init_ns_fd`, `__relibc_init_proc_fd`, `__relibc_init_cwd_ptr`, `__relibc_init_cwd_len`, `__relibc_init_environ`
- Rust generates `local: *;` version scripts that hide these symbols — must inject into global section
- PT_GNU_STACK has `p_align=0` → guard with `core::cmp::max(p_align, 1)` to prevent division by zero
- `libstdcxx-shim.so` provides libstdc++.so.6 symbols from libc++.a (rustc's LLVM needs it)
- RUNPATH `$ORIGIN` resolves to real path, not symlink path — copy .so files alongside binaries

## Cross-Compilation

### CC Wrapper Pattern
```bash
# Compile-only: pass through to clang
for arg in "$@"; do case "$arg" in -c|-S|-E|-M|-MM) exec clang "$@" ;; esac; done
# Link step: add CRT + force static
exec clang -static $SYSROOT/lib/crt0.o $SYSROOT/lib/crti.o "$@" \
  -l:libc.a -l:libpthread.a $SYSROOT/lib/crtn.o
```
- `-l:libc.a` forces static libc when both .a and .so exist
- `-nostdlib` in LDFLAGS breaks autotools configure tests
- Detect `-shared` flag: skip crt0.o, use `-lc` dynamic instead of `-l:libc.a`
- Filter out `-lgcc_s` (symbols are in `libgcc_eh.a`)
- Expand `@file` response files before processing (rustc uses them for 50+ args)
- `-Wl,` comma splitting: `-Wl,-z,relro,-z,now` → `-z relro -z now`

### Toolchain rlibs
- Rust nightly ships 26 pre-compiled rlibs for x86_64-unknown-redox
- Do NOT use `-Z build-std` for userspace — just use the toolchain's rlibs
- Kernel/bootloader STILL need `-Z build-std` (different target triples)
- `--allow-multiple-definition` needed (relibc bundles core/alloc)

### Vendor Management
- `fetchCargoVendor` ONLY works when Cargo.lock exists
- Patching vendored crates requires regenerating `.cargo-checksum.json` (SHA-256)
- Both `snix.nix` and `snix-source-bundle.nix` need the SAME vendor hash
- Git dependencies need `gitSources` in package args for offline vendor config
- `fetchCargoVendor` registry bundles may be laid out as `vendor/source-registry-0/*` — `.cargo/config.toml` must point Cargo at that exact directory, not just `vendor/`
- ring crate from git needs `pregenerated/` assembly files not in registry download
- cc-rs 1.2.x depends on `shlex` crate — must vendor both cc AND shlex for offline builds

### C Library Cross-Compilation
- CRITICAL: C builds CANNOT build test/app binaries — `-nostdlib -static` in LDFLAGS
- Build only `.a` targets, install manually
- cmake: `-DCMAKE_C_FLAGS` on cmdline REPLACES `CMAKE_C_FLAGS_INIT` from toolchain — never set on cmdline
- cmake: `CHECK_TYPE_SIZE(pid_t PID_T)` sets `HAVE_PID_T` and `PID_T` (not `SIZE_OF_PID_T`)
- autotools: `CHOST` env var for cross-detection, `touch` timestamp ordering matters
- gnulib: replace ONLY `lib/stddef.h` and `lib/stdint.h` with `#include_next` — do NOT replace all
- gettext: Redox is C-locale only — use stub passthrough implementations
- harfbuzz: needs minimal C++ header stubs (type_traits, atomic, etc.), NOT full libc++

### LLVM/libc++ for Redox
- libc++ needs `-fexceptions -funwind-tables` for exception handling (cmake depends on this)
- `-DLIBCPP_PROVIDES_DEFAULT_RUNE_TABLE` required (not Bionic/musl/glibc)
- `-D_LIBUNWIND_USE_DL_ITERATE_PHDR=1` required (CMAKE_SYSTEM_NAME=Generic doesn't trigger it)
- `link.h` stub with `struct dl_phdr_info` using raw types (relibc's elf.h uses `struct Elf64_Phdr`)
- LLD MachO/COFF backends disabled — only ELF+Wasm

## Nix Build System

### String Escaping in `''` Blocks
- `''` (two single-quotes) terminates Nix indented strings — use `""` for empty strings
- Python `'''` contains `''` — never use triple-quoted Python strings in Nix `''` blocks
- `echo ''` terminates the Nix string — use `echo ""`
- `${var}` gets interpolated — use `''${var}` for literal `${var}` in output
- `$'\033'` syntax doesn't work in heredocs — set color variables before the heredoc
- `get('key', '')` in Python terminates the Nix string — use `str()` instead

### Heredoc Indentation Rule
- Nix `''` strings strip the MINIMUM indentation across ALL lines
- ONE line at column 0 sets minimum to 0 → NO stripping → ALL heredoc terminators break
- ALL non-empty lines must have at least N spaces for N-space stripping
- Heredoc terminators at N-space indent → 0-space after stripping → bash finds them
- `nix fmt` / nixfmt can re-indent and break heredoc terminators — verify after formatting
- Add files with heredocs to treefmt/git-hooks excludes

### Flake File Tracking
- New `.nix` files MUST be `git add`ed before `nix build` (flake only sees tracked files)
- `adios.lib.importModules` auto-discovers .nix files in modules/ — but only tracked ones
- New source files (`.rs`) in flake-referenced paths also need `git add`

### Dotfiles in Copy Operations
- `cp -r dir/*` does NOT match dotfiles (`.cargo/`, `.config/`, etc.) — bash glob skips them
- Use `cp -r dir/.` to copy ALL contents including dotfiles
- The build module's `extraPaths` copies use this pattern for disk image assembly
- Source bundles with `.cargo/config.toml` silently lost their config when `/*` was used

### Vendor Hash Workflow
- crates.io `fetchurl` hashes go stale — crates.io regenerates tarballs periodically, changing the hash even for the same version
- Dummy hash `sha256-0000...` triggers mismatch error revealing the real hash
- Nix 2.31 FOD reference check: test fixture files with `/nix/store/` paths → `fixed-output derivations must not reference store paths`
- The check only fires on hash MISMATCH — correct hash skips it
- Workaround: vendor locally instead of git dependencies, or compute hash outside FOD

### Module System (adios)
- adios `extend` uses `//` at module path level — overrides REPLACE the entire module path
- Must resolve profile definitions first, then merge with existing values
- Build module `/build` is the ONLY cross-module consumer — new modules add inputs there
- ALL option fields must be accessed somewhere in build module — Nix is lazy, unread fields skip validation
- `or` defaults (e.g., `inputs.time.hwclock or "utc"`) still validate if the attribute exists
- Use `lib.optionalAttrs` to gate conditional config files on enable flags
- Duplicate attrset keys: later one silently wins
- Korora types: `t.int` (not `t.integer`), `t.bool`, `t.string`

## Syscall Debugging

### strace-redox (Userspace)
- Included in `development.nix` profile — `strace /bin/ls` or `strace -p PID`
- Output goes to stderr; no kernel rebuild needed
- Can't trace scheme daemons or early boot

### Kernel syscall_debug
- Module option: `"/boot".kernelSyscallDebug = true;` swaps in debug kernel
- Standalone build: `nix build .#kernelSyscallDebug`
- Per-process filtering: `mkKernelSyscallDebug { debugProcesses = ["cargo"]; }`
- Output goes to serial console — capture with `2>&1 | tee trace.log`
- Filters out `clock_gettime`, `yield`, `futex`, stdout/stderr writes by default
- Heavy performance impact — traces ALL syscalls from matching processes
- Full docs: `docs/syscall-debugging.md`

## VM Testing

### Boot Milestones for `vm_serial expect:`
- `"Redox OS Bootloader"` — bootloader started
- `"Redox OS starting"` — kernel started
- `"Boot Complete"` — rootfs mounted, init scripts done
- `"[#$] "` — shell prompt ready (headless only)
- `"GraphicScreen"` — Orbital allocated display buffer

### Serial Console
- Graphical profile: serial input doesn't work (`debug:` lacks tcsetattr), serial READ works
- Cloud Hypervisor: `--serial tty` needs terminal raw mode (`stty raw -echo`) for input
- Cloud Hypervisor: `--serial file=path` + grep polling is the reliable test pattern
- QEMU: `-vga none` required for headless (otherwise bootloader waits for resolution selection)
- Expect `-re ".+"` fails on ANSI escape codes — use file-based polling instead

### Test Script Idioms
- Emit `FUNC_TEST:name:PASS/FAIL` directly — don't rely on exit codes through Ion
- Use `/nix/system/profile/bin/bash -c '...'` for complex logic (not bare `bash`)
- `set -e` in bash -c blocks kills silently on any error — handle errors explicitly
- Test profiles WITHOUT userutils use `/startup.sh`; WITH userutils use getty
- functional-test and minimal profiles MUST NOT include userutils

## Self-Hosting (Rust Toolchain on Redox)

### What Works
- `rustc` compilation (single files, multi-file, proc-macros)
- `cargo build` (hello world, dependencies, vendored deps, path deps, build scripts)
- `snix build --expr/--file` (Nix derivations built on Redox)
- `snix build .#ripgrep` (flake installables, 33 crates compiled)
- `snix build .#hello` (flake installables)
- workspace builds via `snix build` (multi-crate)
- focused `snix-sandbox-test` rerun (2026-04-07): `snix-simple`, `snix-build-cargo`, `flake-build`, `cc-dep-build`, `workspace-build`, and `rg-build` all pass (6/6; see `/home/brittonr/.local/share/pueue/task_logs/37.log`)
- `cc-dep-build` fix was in the test fixture, not `snix-redox` sandbox code: (1) Ion builder scripts cannot `let HOME = ...`, so use bash; (2) `cc` 1.2.21 needs vendored `shlex` for offline builds
- `rg-build` fix was also in the test fixture/bundle: (1) ripgrep builder must use bash because it sets `HOME`; (2) `ripgrep-source-bundle.nix` must point Cargo at `vendor/source-registry-0`, matching `fetchCargoVendor` output
- `source-rebuild` fix was in the self-hosting test fixture: seed the temp manifest from `/etc/redox-system/manifest.json` instead of an empty manifest (otherwise activation rebuilds the live profile with only the source-built package), and use full paths like `/bin/mkdir` in `packageSources` test derivations because source-rebuild builders do not get `PATH`
- `snix-compile` fixture had the same two harness issues as ripgrep: `build-snix.nix` needed a bash builder and `build-snix.sh` needed a real bash rewrite with `set -e`; `snix-source-bundle.nix` also had to point Cargo at `vendor/source-registry-0` and `vendor/source-git-0`
- exact rerun of commit `c6a29e00` (2026-04-08) shows: focused `snix-sandbox-test` passes 6/6 in 243s, but full `self-hosting-test` times out at 2400s with only 70 tests reporting before `snix self-compile` finishes
- `snix-compile` moved to run before `source-rebuild` (source-rebuild's activate() drops ld.lld from profile)

### What Doesn't
- `snix-compile` (self-build): with the current committed test profile, the 168-crate self-build does not finish within the 2400s full-suite timeout; exact reruns stall inside `snix build --file` after 70 tests have reported
- there may be a later proc-macro/build-script linking failure (`failed to initiate panic, error 0` from unwind stubs), but do not treat that as the committed baseline until it is reproduced on an exact rerun
- `CARGO_BUILD_JOBS > 1` had two issues: (1) lld stack overflow — fixed by `lld-wrapper` (16MB stack thread + exec); (2) cargo job manager hangs on multi-crate workspace builds — fixed by `patch-relibc-fork-lock.py` (see below)
- `env!("CARGO_PKG_*")` in proc-macro crates: works via DSO environ propagation

### Self-Hosting Baseline (2026-04-08 exact rerun)
- Sandbox mode: scheme-only (per-path proxy disabled due to kernel deadlock)
- Focused `snix-sandbox-test`: 6 pass, 0 fail out of 6 tests; exact rerun of detached worktree commit `c6a29e00`; total time 243s
- Full `self-hosting-test`: tests do NOT complete within the 2400s timeout on detached worktree commit `c6a29e00` or on the current working tree; summary at timeout is 70 pass, 0 fail, 70 total reported
- Last serial lines before timeout show the suite stalled in `--- snix self-compile: snix build --file ---`
- Test order: snix-compile moved BEFORE source-rebuild (source-rebuild's activate() drops ld.lld from the live profile)
- Reproduced passing tests before the timeout include cargo builds and ripgrep (`snix-build-cargo`, `cc-dep-build`, `workspace-build`, `rg-build`, `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`, `parallel-jobs2`)
- The fixture-side lessons still stand: use bash for builders that need `HOME`; vendor missing crates; point Cargo at `vendor/source-registry-0` when using `fetchCargoVendor`; add `vendor/source-git-0` for git deps; seed source-rebuild tests from the real system manifest; and use full paths in source derivations when builder `PATH` is empty
- `--no-sandbox` flag now threads through flake installables (previously bypassed)
- focused test harness note: `snix-sandbox-test` originally checked `$out/bin/workspace-test`, but `workspace-build.nix` installs `$out/bin/mybin`

### Key Patches (all still required)
**relibc** (13 patches): abort-dso, chdir-cwd, dso-environ, environ-dso-init, execvpe, fcntl-lock, fork-lock,
ld-so-align, ld-so-argv-utf8, ld-so-cwd, ld-so-dso-init, pipe-cloexec, randd-read
**cargo** (3 patches): read2-pipes, redox-paths, blake3-redox (in vendor)
**rustc** (4 patches): execvpe, read2-pipes, rustc-flags, allocator-shim

### Fork Thread Safety (CLONE_LOCK)
- CLONE_LOCK (RwLock) serializes fork (write) and thread creation (read)
- Futex-based RwLock has a lost-wake bug: CoW address space duplication during fork copies futex_wait kernel state, futex_wake targets wrong physical page
- Fix: `patch-relibc-fork-lock.py` replaces CLONE_LOCK with AtomicI32 + sched_yield() (no futex)
- State: 0=unlocked, >0=reader count, -1=exclusive (fork)
- `enable_alloc_after_fork()` (allocator pthread_atfork hooks) is NEVER called — no allocator lock during fork
- `fork_impl()` is thread-safe when called concurrently without any locking
- Any futex-based primitive can hit the same CoW bug in multi-threaded fork scenarios

### Allocator Shim
- 7 symbols with v0 mangling + `__rustc` crate hash (deterministic per rustc version)
- Hash extracted at build time via `llvm-nm --defined-only` on rlibs
- Installed as `liballoc_shim.a` in sysroot/lib

## Build Bridge (virtio-fs)

### virtio-fsd
- Response buffers MUST be `sizeof(FuseOutHeader) + requested_size` (virtiofsd uses descriptor size for preadv2 length)
- Non-power-of-two phys_contiguous bug FIXED via `patch-kernel-p2frame-init.py` — kernel now initializes all 2^order frames and uses bulk `deallocate_p2frame` on free
- `round_to_p2_pages()` retained as defense in depth (drivers should not depend on kernel correctness for DMA safety)
- Redox open flags must be translated to Linux FUSE flags via `redox_to_fuse_flags()`
- `--cache=never` on virtiofsd for live push detection (otherwise dir entries cached)

### Binary Cache
- Flat layout: NARs in cache root (not `nar/` subdirectory)
- narinfo `URL:` field rewritten from `nar/hash.nar.zst` to `hash.nar.zst`
- FileHash in nix-compat narinfo parser ONLY accepts nixbase32 (not hex)
- NarHash accepts both hex (64 chars) and nixbase32 (52 chars)
- nixbase32 alphabet: `0123456789abcdfghijklmnpqrsvwxyz` — letters NOT in set: e, o, t, u
- Cache files need chmod 644 / dirs 755 for virtiofsd access

## Disk Image

### Size Requirements
- Default: 768MB (200MB ESP + ~568MB RedoxFS)
- Graphical: 1024MB (Orbital + orbdata + audio drivers)
- Bridge test: 1536MB (25 packages = 277MB NAR)
- `redoxfs-ar` requires pre-allocated image file (`dd if=/dev/zero`)
- `redoxfs-ar --max-size` defaults to 64 MiB — graphical initfs needs 128

### Bare Metal ACPI Workarounds
- Alder Lake-N (N100/N150) firmware references phantom Thunderbolt `_SB_.PC00.TXHC`
- AML interpreter returns `LevelDoesNotExist` error — acpid logs it and continues
- `hwd.probe()` reads `/scheme/acpi/symbols` after the error → **deadlocks** in acpid event loop
- acpid IS required — PCI BAR mapping needs it for USB, NVMe, network on Alder Lake-N
- Fix: override initfs scripts to start acpid + pcid directly, skip hwd entirely
- Override `40_hwd.service` (→ acpid), add `40_pcid.service` (→ pcid), override `40_pcid-spawner.service` (→ depends on both)
- Without acpid: boots to login but USB HID doesn't work (JetKVM shows "USB not connected")
- Confirmed working on: GMKtec NucBoxG3 Plus (N150), LattePanda Mu (N100, no workaround needed)

### Init Scripts
- After rootfs switchroot, init PATH = `/usr/bin` (from `prefix: "/usr"`)
- Rootfs service binaries at `/bin/` or `/nix/system/profile/bin/` are NOT in init's PATH
- `renderServiceToml` uses `baseNameOf` on command — strips `/bin/` prefix by default
- Fix: check `hasPrefix "/"` and preserve full path; or ensure binary is in `/usr/bin/`
- Rootfs oneshot services may fail silently — no error output visible without serial console
- Numbered: 00_base, 12_stored, 13_profiled, 20_orbital, 30_console, 90_exit_initfs
- `notify` blocks until daemon signals readiness; `nowait` fires and forgets
- Our init (base fc162ac) does NOT support inline `KEY=VALUE cmd` syntax — use `export` on separate line
- `ptyd` must be started (notify) in 00_base — getty needs pty: scheme
- `acpid` is spawned by pcid-spawner — do NOT notify directly
- `audiod` uses `daemon` type (notify); if no audio HW, it exits and parent gets EOF → continues
- VT=3 for Orbital (VT=1 conflicts with inputd, VT=2 with fbcond)

### I225/I226 (igc) NIC Driver Notes
- RDT register write MUST happen AFTER RXDCTL.ENABLE is set — hardware silently ignores earlier writes
- RCTL_UPE (promiscuous mode) causes boot deadlock — interrupt storm before event loop runs
- `log::debug!` level logging deadlocks during initfs boot (too many writes through logging scheme)
- redox-log file output (`/scheme/logging/`) always 0 bytes during initfs boot
- Driver diag path: `cat /scheme/network.*/diag` — reads registers from driver's own event loop, only reliable diagnostic
- smolnetd netcfg scheme hardcodes interface as `eth0` — use `eth0` for configuration, not PCI-path names
- smolnetd signals readiness (daemon.ready()) BEFORE registering netcfg scheme (race window)

### snix TLS/CA Certificate Handling
- Redox has no system CA certificate store — `rustls-native-certs` panics with "No CA certificates were loaded"
- `SSL_CERT_FILE=/dev/null` does NOT fix it — Redox's rustls-native-certs doesn't support env vars
- reqwest with `rustls-no-provider` feature strips TLS config methods (`tls_built_in_root_certs`, `tls_built_in_native_certs`, `danger_accept_invalid_certs` all absent)
- Fix: change `http_client` from `Client` to `Option<Client>`, store `None` on build failure
- Patch goes in `extraCrateOverrides.snix-glue` in `packages.nix` (NOT in `snix.nix` — that file isn't used for system image builds)
- snix system image binary is built via `mkCrossPackage` in `packages.nix`, not `mkBinary` in `snix.nix`
- `self.http_client.get(...)` → `self.http_client.as_ref().expect("HTTP client not available").get(...)`

### Clang on Redox
- Clang works for C/asm compilation on Redox with `-no-canonical-prefixes` + explicit `-resource-dir`
- Without `-no-canonical-prefixes`: `realpath` returns `file:/path` → InstalledDir empty → cc1 exec fails
- Without explicit `-resource-dir`: clang can't find stddef.h/stdarg.h (resource headers)
- `cc-rs` crate needs `AR=/nix/system/profile/bin/llvm-ar` — no bare `ar` binary on Redox
- `-isystem $S/include` for sysroot C headers — do NOT use `--sysroot` (overrides resource header search)
- Compile-only detection in CC wrapper: `-c`, `-S`, `-E`, `-M`, `-MM` → pass to clang, rest → ld.lld

### Multi-User Namespaces
- Upstream userutils `login` reads `/etc/login_schemes.toml` → calls `mkns()` → `setns()` to create per-user namespace
- Format: `[user_schemes.<name>]\nschemes = ["scheme1", "scheme2"]` — TOML parsed by `login.rs`
- `sudo` binary is also the scheme daemon (`--daemon` mode) — registers `sudo:` scheme
- Privilege escalation via `SetResugid` proc_call on caller's process fd
- `su` opens `/scheme/sudo/su` — authenticates with target user's password
- `su` has NO `-c` flag — spawns an interactive shell only
- Ion single quotes prevent all expansion but `$()` inside them still crashes Ion at parse time
- Test scripts with `bash -c` must use double quotes OR write bash to a file and execute it
- Test script numbering matters: `21-e2e-rebuild.ion` emits its own `FUNC_TESTS_COMPLETE` — tests numbered 22+ never get counted by the harness

### Shadow Passwords
- Must be Argon2id PHC format (`$argon2id$v=19$...`) — plaintext causes panic
- Empty password `user;` skips verification (OK for defaults)
- Deterministic salt `redox-$username` keeps builds reproducible (not production security)

## Nix Store Permissions
- Nix store strips write bits: `chmod 755` → `555`, `chmod 644` → `444`
- Tests checking file modes must use Nix-adjusted values
- Must `chmod u+w` directory before copying additional files into store copies

### Sandbox Proxy Deadlock (per-path proxy DISABLED)
- The proxy deadlocks on the first builder file: request — snix build hangs indefinitely
- Root cause: kernel blocks ALL file: scheme I/O from processes owning a scheme socket
- The proxy owns a scheme socket (registered as file: in child namespace)
- When the proxy thread does `raw_openat(root_fd, ...)`, this is a file: operation (root_fd points to redoxfs)
- Even though root_fd bypasses initnsmgr, the kernel still blocks it because the process owns a scheme socket
- `libredox::call::setns()` correctly updates relibc's DYNAMIC_PROC_INFO.ns_fd (not the issue)
- exec correctly passes ns_fd through auxv AT_REDOX_NS_FD=43 (not the issue)
- relibc_start_v1 reads ns_fd/proc_fd from auxv, initializes correctly (not the issue)
- The original hypothesis about relibc fd state was wrong — the actual problem is kernel-level scheme I/O blocking
- Non-proxy sandbox (scheme-level with real file:) works because no scheme socket is owned
- Fix: proxy disabled in local_build.rs; scheme-level sandbox used as default; proxy code preserved for future kernel fix
