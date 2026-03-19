# Archive: fuse-errno-mapping
**Date:** 2026-03-19
**Status:** Implemented

## Summary
Implemented proper errno mapping between FUSE transport and Redox error codes.
Ensures correct error propagation in virtio-fs scheme for file system operations.

## Key Files
- nix/pkgs/system/virtio-fsd/src/scheme.rs fuse_transport_to_redox()
