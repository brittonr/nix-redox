# Archive: namespace-sandboxing
**Date:** 2026-03-19
**Status:** Implemented

## Summary
Implemented namespace-based build sandboxing using per-path proxy for Nix builds.
Provides isolation and dependency control for secure package builds on Redox.

## Key Files
- snix-redox/src/sandbox.rs
- snix-redox/src/local_build.rs setup_proxy_namespace()
