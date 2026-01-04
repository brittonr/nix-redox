# SNIX: Complete Technical Analysis

## Overview

**SNIX** is a modern Rust re-implementation of the Nix package manager, forked from Tvix. It provides a modular, protocol-based architecture that solves fundamental problems with the original C++ Nix implementation.

## Core Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        snix-cli                              │
│              (REPL, command-line interface)                  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────┴──────────────────────────────────┐
│                        snix-glue                             │
│         (Integration layer, build/import builtins)           │
└─────┬────────────────────┬──────────────────────┬───────────┘
      │                    │                      │
┌─────┴──────┐      ┌──────┴───────┐      ┌──────┴───────────┐
│ snix-eval  │      │  snix-store  │      │   snix-build     │
│ (Bytecode  │      │ (Nix store   │      │ (Build protocol, │
│  VM)       │      │  metadata)   │      │  backends)       │
└────────────┘      └──────┬───────┘      └──────────────────┘
                           │
                    ┌──────┴───────┐
                    │ snix-castore │
                    │ (Content-    │
                    │  addressed)  │
                    └──────────────┘
```

## Key Components

### 1. snix-eval - Nix Language Evaluator

A **bytecode-compiled VM** (unlike C++ Nix's AST tree-walker):

| Component | Purpose |
|-----------|---------|
| **Compiler** | Converts rnix AST to bytecode with scope analysis |
| **VM** | Executes bytecode with generators for suspendable operations |
| **Builtins** | Native Rust implementations of Nix built-ins |
| **Values** | Runtime types: `NixAttrs`, `NixList`, `NixString`, `Value` |
| **EvalIO** | Trait for filesystem/store abstraction |

**Performance**: ~10x faster than C++ Nix in many benchmarks.

### 2. snix-castore - Content-Addressed Storage

A Nix-agnostic storage layer using BLAKE3 digests:

```rust
trait BlobService {
    fn has(&self, digest: &B3Digest) -> bool;
    fn open_read(&self, digest: &B3Digest) -> Box<dyn Read>;
    fn put(&self, data: impl Read) -> B3Digest;
}

trait DirectoryService {
    fn get(&self, digest: &B3Digest) -> Option<Directory>;
    fn put(&self, directory: Directory) -> B3Digest;
}
```

**Storage Efficiency**: Replit achieved **90% reduction** (6TB -> 1.2TB) through content-addressed deduplication.

### 3. snix-build - Build Protocol

Pluggable build backends via gRPC protocol:

| Backend | Description |
|---------|-------------|
| **OCI Builder** | Uses runc with OCI runtime spec |
| **gRPC Remote** | Distributed builds over network |
| **MicroVM** | Cloud Hypervisor/Firecracker isolation (planned) |
| **Kubernetes** | Pod-based builds (planned) |
| **Bubblewrap** | Lightweight Linux namespaces (planned) |

### 4. snix-store - Nix Metadata

Adds Nix-specific metadata on top of castore:

```rust
struct PathInfo {
    root_node: Node,              // Points into castore
    references: Vec<StorePath>,   // Dependencies
    nar_size: u64,
    nar_sha256: [u8; 32],
    signatures: Vec<Signature>,
}
```

## Comparison: SNIX vs C++ Nix

| Aspect | C++ Nix | SNIX |
|--------|---------|------|
| **Language** | C++ | Rust |
| **Evaluation** | AST tree-walking | Bytecode VM |
| **Performance** | Baseline | ~10x faster |
| **Architecture** | Monolithic | Modular/protocol-based |
| **Store** | NAR-addressed | Content-addressed |
| **Sandboxing** | Platform-specific | Pluggable backends |
| **IFD** | Blocking | Optimized |

## Data Flow

```
.nix file
    │
    ▼
rnix-parser (AST)
    │
    ▼
snix-eval Compiler (bytecode)
    │
    ▼
snix-eval VM (Values)
    │
    ▼
derivation builtin -> Derivation struct
    │
    ▼
derivation_to_build_request() -> BuildRequest proto
    │
    ▼
BuildService backend -> outputs
    │
    ▼
castore (blobs + trees) + store (metadata)
```

## Project Statistics

- **Primary Language**: Rust (39.8%), Nix (58.1%)
- **Commits**: 22,116+
- **License**: GPL-3.0 (MIT for protobuf definitions)
- **Active Development**: January 2026

## Key Innovations

1. **Bytecode Compilation**: Enables optimization passes before execution
2. **Content-Addressed Storage**: Granular deduplication, not entire NARs
3. **Protocol-Based IPC**: gRPC boundaries allow component substitution
4. **Pluggable Builders**: OCI, remote, microVM - no hardcoded sandboxing
5. **NAR Compatibility**: `nar-bridge` serves Nix Binary Cache protocol

## Why SNIX Forked from Tvix

| Tvix Goals | SNIX Goals |
|------------|------------|
| 1:1 C++ Nix replacement | Innovative architecture |
| Traditional store | Content-addressed storage |
| Conservative changes | Rapid experimentation |

## Sources

- [SNIX Official Website](https://snix.dev/)
- [SNIX Rustdoc - snix_eval](https://snix.dev/rustdoc/snix_eval/index.html)
- [SNIX Architecture Docs](https://snix.dev/docs/components/architecture/)
- [SNIX Git Repository](https://git.snix.dev/snix/snix)

## Summary

SNIX represents a significant architectural evolution from C++ Nix, offering:

- **Memory Safety**: Rust ownership vs manual C++ management
- **Performance**: Bytecode VM yields order-of-magnitude speedups
- **Modularity**: Replace any component without full rewrites
- **Efficiency**: 90% storage reduction through content-addressing
- **Compatibility**: Full Nixpkgs support via `nix-compat` crate

The project provides the most promising path forward for Nix ecosystem evolution while maintaining backward compatibility.
