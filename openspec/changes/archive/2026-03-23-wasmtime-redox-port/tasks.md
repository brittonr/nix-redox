## 1. Host-side feasibility check

- [x] 1.1 Clone Wasmtime v43 source and run `cargo check --target x86_64-unknown-redox` with minimal features to identify all compilation failures
- [x] 1.2 Catalog every crate that fails to compile for Redox — record the crate name, failing file, and root cause (missing cfg gate, missing libc type, rustix gap, etc.)
- [x] 1.3 Verify `wasmtime compile --target pulley64 hello.wasm` works on the host (produces `.cwasm` file) — this confirms the host-side precompilation path

## 2. Vendor and patch dependencies

- [x] 2.1 Create `nix/pkgs/userspace/wasmtime-redox.nix` package skeleton using `mkBinary` from `mk-userspace.nix`, pinning Wasmtime v43.0.0 source and setting `vendorHash`
- [x] 2.2 Add Wasmtime source as a flake input (or fetchFromGitHub) for the pinned v43.0.0 release tag
- [x] 2.3 Apply the two wasmtime source patches: `sys/mod.rs` (route Redox to custom module) and `build.rs` (exclude Redox from supported_os)
- [x] 2.4 Compile and link `wasmtime-platform-redox.c` providing the wasmtime_* mmap/tls symbols
- [x] 2.5 Run initial `nix build` with dummy vendorHash to trigger the vendor fetch, capture the real hash (sha256-WJz7J9FHGRqni889o2omkC1K+rwZ8iM6SarT1nd1p0Q=)
- [x] 2.6 Configure Cargo feature flags in the Nix package: CLI `--no-default-features -F compile,cranelift,pulley,wat,logging -F wasmtime/custom-virtual-memory -F wasmtime/runtime`

## 3. Cross-compilation integration

- [x] 3.1 Verify the Nix package compiles through Cranelift codegen crates (pure Rust, should work but largest part of the build)
- [x] 3.2 Verify Pulley interpreter crate compiles (pure Rust, no OS deps)
- [x] 3.3 Debug and fix any link-time failures — missing symbols from relibc, linker wrapper issues with the large binary
- [x] 3.4 Confirm the output binary is a valid x86-64 ELF (file command check) — 15MB statically linked ELF
- [x] 3.5 Strip debuginfo from the binary and check final size is reasonable (<50MB) — 15MB

## 4. Flake integration

- [x] 4.1 Expose `wasmtime-redox` in `nix/flake-modules/packages.nix` as a flake package output
- [x] 4.2 Add `wasmtime` to the `development.nix` profile package list
- [x] 4.3 Verify `nix build .#wasmtime-redox` succeeds end-to-end from a clean build — 33s build time

## 5. Test WASM module and host precompilation

- [x] 5.1 Write a minimal WASM module (WAT text format) that tests i32.add arithmetic — no WASI needed
- [x] 5.2 Create a Nix derivation (`wasmtime-precompile.nix`) that compiles hello.wat to Pulley bytecode using host wasmtime
- [x] 5.3 Verify the `.cwasm` file is produced (67KB Pulley bytecode) and source `.wat` is included

## 6. VM smoke test

- [x] 6.1 Add `wasmtime-redox` to functional-test and development profiles
- [x] 6.2 Write test script `20-wasmtime.ion` that runs `wasmtime --version` and `wasmtime compile` on device, emits FUNC_TEST:wasmtime-version:PASS/FAIL and FUNC_TEST:wasmtime-compile:PASS/FAIL
- [x] 6.3 Test script auto-discovered by functional-test profile (reads all .ion files from test-scripts/)
- [x] 6.4 Functional test check builds successfully — disk image includes wasmtime binary, test script ready for VM execution
