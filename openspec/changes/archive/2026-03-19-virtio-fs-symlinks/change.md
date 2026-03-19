# Archive: virtio-fs-symlinks
**Date:** 2026-03-19
**Status:** Implemented

## Summary
Implemented symbolic link support in virtio-fs scheme with FUSE_READLINK handling.
Enables proper symlink resolution and following in shared filesystem access.

## Key Files
- nix/pkgs/system/virtio-fsd/src/scheme.rs FUSE_READLINK, symlink following
