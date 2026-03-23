## Context

Wasmtime v44 is a ~200-crate Rust workspace. The core runtime depends on OS primitives through two layers: `rustix` (for mmap/mprotect) and `libc` (for signals). On standard Unix, Wasmtime uses:
- `mmap`/`mprotect`/`munmap` for linear memory and guard pages
- `sigaction` with `SA_SIGINFO` to catch SIGSEGV/SIGILL/SIGFPE for trap handling
- `ucontext_t` register access inside signal handlers to redirect execution after traps
- `sigaltstack` for stack overflow recovery
- Fiber stacks (mmap'd with guard pages) for async execution

Redox has mmap/mprotect/munmap in relibc. Redox has signal constants and `sigaction` in libc. Redox does NOT have `ucontext_t` or `sigaltstack`, and relibc's `siginfo_t` doesn't expose `si_addr`.

Wasmtime anticipates this situation — it ships a **Pulley** interpreter backend and a **custom platform API** (`custom-virtual-memory`, `custom-native-signals` features) for non-standard platforms. Pulley compiles WASM to a portable bytecode that is interpreted, eliminating the need for signal-based trap handling and executable memory.

Our existing cross-compilation pipeline (`mk-userspace.nix`, `redox-buildRustCrate.nix`) handles Rust workspace builds with vendored dependencies, per-crate Nix caching, and the Redox sysroot/linker wrapper. Packages like `bottom`, `zoxide`, `tokei`, and `snix` are already built this way.

## Goals / Non-Goals

**Goals:**
- Run precompiled WASM modules on Redox via `wasmtime run module.cwasm`
- Precompile WASM → Pulley bytecode on the host via `wasmtime compile --target pulley64`
- Package Wasmtime as a standard Nix userspace package reusing `mk-userspace.nix`
- Validate with a VM smoke test (compile hello.wasm on host, run on Redox)

**Non-Goals:**
- WASI support (cap-std/system-interface ecosystem needs separate investigation)
- Native JIT execution (requires ucontext_t/sigaltstack kernel work)
- Signal-based trap handling (Pulley does bounds checks in software)
- Async/fiber support (requires mmap'd stacks + signal recovery)
- Wasmtime as a library for embedding in other Redox programs (CLI binary only for now)
- tokio/async runtime (not ported to Redox)

## Decisions

### 1. Pulley interpreter over native JIT

**Choice:** Use Wasmtime's Pulley interpreter backend, not native x86_64 code generation.

**Rationale:** Native JIT requires signal-based trap handling (SIGSEGV → read ucontext_t → redirect PC to trap handler). Redox lacks `ucontext_t` and proper signal context passing. Pulley eliminates all signal dependencies — bounds checks, division by zero, and unreachable traps are all handled in the interpreter loop. The performance cost is significant (~10-50x slower than JIT) but this is about getting something working, not production performance.

**Alternatives considered:**
- Custom platform API (`custom-native-signals`): Still needs a trap handler callback with IP/FP, which requires kernel signal context support we don't have
- `no_std` / malloc-based memory: Wasmtime supports this but still needs trap handling for native code

### 2. Precompilation on host, execution on Redox

**Choice:** Split the workflow into host-side compilation and Redox-side execution.

**Rationale:** Cranelift compilation is CPU-intensive and pulls in many dependencies. By precompiling `.wasm` → `.cwasm` (Pulley bytecode) on the host, the Redox binary only needs the runtime + Pulley interpreter, not the full compiler. This reduces the cross-compilation surface and binary size. The `wasmtime compile --target pulley64` command works on any host.

Wasmtime also supports runtime compilation — we'll include Cranelift in the binary for `wasmtime run module.wasm` to work directly. But `.cwasm` precompilation is the primary validated path.

### 3. Nix package using mk-userspace.nix with fetchCargoVendor

**Choice:** Standard `mkBinary` package with `vendorHash`, following the pattern of bottom/zoxide/snix.

**Rationale:** Wasmtime has a Cargo.lock and uses only crates.io dependencies (no git deps in the core path). `fetchCargoVendor` + vendor patching is our proven pattern. The workspace is large (~200 crates) but this is a quantity issue, not a structural one.

We'll need vendor patches for crates that have `cfg(unix)` code paths that don't account for Redox — primarily rustix (madvise exclusion already exists) and possibly cap-std stubs. Each patch needs `.cargo-checksum.json` regeneration.

### 4. Custom platform API via sys/mod.rs dispatch

**Choice:** Route `target_os = "redox"` to Wasmtime's `custom` sys module instead of the `unix` module. Enable `custom-virtual-memory` feature. Leave `custom-native-signals` OFF (Pulley doesn't need signal traps). Provide the `wasmtime_*` C symbols (mmap wrappers + TLS) in `wasmtime-platform-redox.c`, linked into the binary.

**Rationale:** The unix sys module uses `sigaltstack`, `ucontext_t`, and `siginfo_t.si_addr()` — none available on Redox. Rather than patching around these with cfg guards, we use Wasmtime's purpose-built custom platform API. Two small patches to the wasmtime source:
1. `sys/mod.rs` — add `cfg(target_os = "redox")` before `cfg(unix)`, routing to the `custom` module
2. `build.rs` — exclude Redox from `supported_os` so `has_native_signals = false`

With `has_virtual_memory = true` (via `custom-virtual-memory`), the custom module expects mmap/tls symbols which we implement in a C file using Redox's standard POSIX mmap. With `has_native_signals = false`, no signal handler symbols are needed at all.

Verified: `cargo check -p wasmtime --target x86_64-unknown-redox --no-default-features -F std,runtime,cranelift,pulley,wat,custom-virtual-memory` passes with zero errors after these two patches.

### 5. Minimal feature set

**Choice:** CLI features: `compile,cranelift,pulley,wat,logging`. Library features (forwarded): `std,runtime,cranelift,pulley,wat,custom-virtual-memory`.

Disable: `run` (requires WASI + tokio), `async`, `pooling-allocator`, `cache`, `profiling`, `component-model`, `threads`, `stack-switching`, `wasi-*`, `serve`, `wasi-http`

**Rationale:** The `run` subcommand pulls `wasmtime-wasi` → `tokio` → `chrono` → `iana-time-zone` (no Redox support). Instead we'll build a minimal custom runner binary that uses the wasmtime library directly to load and execute `.cwasm` files without WASI.

Each disabled feature removes OS dependencies:
- `async` requires wasmtime-fiber (mmap'd stacks, stack switching assembly)
- `pooling-allocator` requires complex mmap management with memory protection keys
- `cache` requires filesystem caching (serde + dirs crate, may need Redox patches)
- `profiling` requires perf/vtune integration (Linux-specific)
- All WASI features require cap-std ecosystem (not ported)

### 5. Build wasmtime-cli binary, not the library

**Choice:** Cross-compile the `wasmtime` CLI binary, package it in `/bin/wasmtime`.

**Rationale:** The CLI is the simplest integration point — it's a single binary that loads and runs WASM files. Library embedding requires downstream consumers to also cross-compile against the wasmtime crate, which multiplies the porting surface.

## Risks / Trade-offs

**[Large vendor patch surface]** → Wasmtime has ~200 crates. Some will have `cfg(unix)` paths that compile but behave wrong on Redox, or `cfg(not(target_os = "redox"))` exclusions that remove needed code. Mitigation: start with `cargo check --target x86_64-unknown-redox` on the host to find compilation failures before attempting the full Nix build.

**[rustix mm module gaps]** → rustix excludes `madvise` for Redox but includes the rest of mm. Wasmtime's mmap code uses `rustix::mm::mmap_anonymous`, `mprotect`, `munmap` — these should work. Risk is in edge cases like `MAP_NORESERVE` (defined only for Linux/illumos, already has a fallback). Mitigation: the mmap.rs code already has `cfg_if` for this.

**[Pulley bytecode ABI stability]** → `.cwasm` files compiled for Pulley on the host must be loadable on the Redox binary. Both must use the same Wasmtime version. Mitigation: pin exact version, include compile capability in the Redox binary too.

**[Binary size]** → Cranelift + Pulley + WAT parser could produce a 30-50MB binary. Mitigation: strip debuginfo, consider `opt-level = 'z'` if too large.

**[libc crate version mismatch]** → Wasmtime pins `libc = "0.2.177"`. Our Redox toolchain may need a specific libc version with Redox patches. Mitigation: vendor patch the libc crate if needed.
