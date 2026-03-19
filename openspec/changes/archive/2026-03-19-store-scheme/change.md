# Archive: store-scheme
**Date:** 2026-03-19
**Status:** Implemented

## Summary
Implemented Nix store scheme daemon providing /nix/store access to Redox userspace.
Enables transparent access to store paths with lazy loading and efficient handle management.

## Key Files
- snix-redox/src/stored/ (2487 lines: scheme.rs, handles.rs, lazy.rs, resolve.rs, mod.rs)
