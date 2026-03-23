## Why

Redox OS needs a WebAssembly runtime to run WASM modules — a prerequisite for sandboxed plugin systems, portable binaries, and WASI-based tooling. Wasmtime is the leading production-quality WASM runtime, written in Rust, with explicit support for non-standard platforms through its custom platform API. No WASM runtime has been ported to Redox yet.

## What Changes

- Add a new Nix package that cross-compiles Wasmtime for `x86_64-unknown-redox` using the Pulley interpreter backend (avoids signal handling and JIT code execution requirements that Redox doesn't fully support yet)
- Vendor and patch Wasmtime's dependency tree for Redox compatibility (rustix mm module, libc cfg gates, etc.)
- Provide a `wasmtime` binary on Redox that can load and execute precompiled WASM modules (`.cwasm` compiled to Pulley bytecode on the host)
- Include the `wasmtime` package in self-hosting and development profiles so it's available on disk images

## Capabilities

### New Capabilities
- `wasmtime-package`: Nix cross-compilation package for Wasmtime targeting Redox, using Pulley interpreter mode with minimal feature set (no async, no WASI, no signal-based traps)
- `wasmtime-vm-test`: VM-level smoke test that precompiles a WASM module on the host, includes it in the disk image, and runs it under Wasmtime on Redox to verify end-to-end execution

### Modified Capabilities

## Impact

- **Nix packages**: New `nix/pkgs/userspace/wasmtime-redox.nix` and vendored patches
- **Disk image**: Adds ~5-15 MB binary to profiles that include it
- **Dependencies**: Wasmtime v44 source, vendored crate patches for Redox (rustix, libc, possibly cap-std stubs)
- **Build time**: Wasmtime is a large workspace (~200+ crates including Cranelift); cross-compilation will take several minutes
- **Profiles**: `self-hosting.nix` and `development.nix` gain wasmtime in their package lists
