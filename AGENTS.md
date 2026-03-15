# AGENTS.md — Permanent Build Knowledge

Hard-won lessons from building RedoxOS with Nix. Read before making changes.

## Redox OS Platform

### Ion Shell (NOT POSIX)
- Variables: `let var = "value"` (not `var="value"`)
- Arrays: `@array` sigil (strings use `$var`)
- Control flow ends with `end` (not `fi`, `done`)
- `else if` (not `elif`), no `then` keyword
- Redirect stderr: `^>` (not `2>`)
- Export: `export VAR value` (not `export VAR=value`); `export VAR` alone fails if VAR doesn't exist
- `$()` command substitution crashes on empty output: `let var = $(grep ...)` → "Variable '' does not exist"
- `@()` process expansion unreliable with pipes and `matches`
- No heredoc (`<< EOF`) support
- Single quotes prevent all expansion — safe for Nix expressions with `{}[]()`
- Apostrophes in `bash -c '...'` blocks break Ion's quote parser
- `$?` unreliable between external commands — emit PASS/FAIL directly from bash blocks
- `echo $var | grep` pipes fail silently — use Ion-native `test` or `is` for comparisons

### Available Commands
**In uutils**: cat, cp, df, du, echo, head, ls, mkdir, mv, pwd, rm, sort, touch, uniq, wc
**In extrautils**: grep, less, tar
**NOT available**: dd, tail, sleep, sed, awk, cut, find, chmod (use full path `/nix/system/profile/bin/chmod`)
- `grep` has no `\|` alternation or `-E` extended regex — use separate grep calls
- `sleep` binary not in uutils (not compiled) — use `read -t N < /dev/null` in bash or FUSE I/O ops in Ion
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
- ring crate from git needs `pregenerated/` assembly files not in registry download

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

### What Doesn't
- `CARGO_BUILD_JOBS > 1` had two issues: (1) lld stack overflow — fixed by `lld-wrapper` (16MB stack thread + exec); (2) cargo job manager hangs on multi-crate workspace builds — fixed by `patch-relibc-fork-lock.py` (see below)
- `env!("CARGO_PKG_*")` in proc-macro crates: works via DSO environ propagation

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

### Init Scripts
- Numbered: 00_base, 12_stored, 13_profiled, 20_orbital, 30_console, 90_exit_initfs
- `notify` blocks until daemon signals readiness; `nowait` fires and forgets
- Our init (base fc162ac) does NOT support inline `KEY=VALUE cmd` syntax — use `export` on separate line
- `ptyd` must be started (notify) in 00_base — getty needs pty: scheme
- `acpid` is spawned by pcid-spawner — do NOT notify directly
- `audiod` uses `nowait` (no HW in headless = no readiness signal)
- VT=3 for Orbital (VT=1 conflicts with inputd, VT=2 with fbcond)

### Clang on Redox
- Clang works for C/asm compilation on Redox with `-no-canonical-prefixes` + explicit `-resource-dir`
- Without `-no-canonical-prefixes`: `realpath` returns `file:/path` → InstalledDir empty → cc1 exec fails
- Without explicit `-resource-dir`: clang can't find stddef.h/stdarg.h (resource headers)
- `cc-rs` crate needs `AR=/nix/system/profile/bin/llvm-ar` — no bare `ar` binary on Redox
- `-isystem $S/include` for sysroot C headers — do NOT use `--sysroot` (overrides resource header search)
- Compile-only detection in CC wrapper: `-c`, `-S`, `-E`, `-M`, `-MM` → pass to clang, rest → ld.lld

### Shadow Passwords
- Must be Argon2id PHC format (`$argon2id$v=19$...`) — plaintext causes panic
- Empty password `user;` skips verification (OK for defaults)
- Deterministic salt `redox-$username` keeps builds reproducible (not production security)

## Nix Store Permissions
- Nix store strips write bits: `chmod 755` → `555`, `chmod 644` → `444`
- Tests checking file modes must use Nix-adjusted values
- Must `chmod u+w` directory before copying additional files into store copies
