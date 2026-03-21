## Why

The virtio-fs driver already has FUSE_READLINK, FUSE_SYMLINK, and symlink-following path resolution implemented. But `O_STAT` opens follow the final symlink component, so `lstat()` / `symlink_metadata()` returns the target's attributes instead of the symlink's. This breaks Nix store access through the build bridge — store paths contain symlinks (e.g., `lib/libfoo.so → libfoo.so.1`), and snix uses `symlink_metadata()` to distinguish symlinks from regular files during NAR hashing, profile management, and GC root handling. The fix is small (add a no-follow variant for O_STAT) but needs a VM test to prove symlinks work end-to-end through the bridge.

## What Changes

- `resolve_path` gains a `follow_last` parameter so O_STAT opens can stop before following the final symlink
- `openat` passes `follow_last: false` when O_STAT is set
- VM functional test validates: readlink through the scheme, stat on symlinks reports S_IFLNK, directory listings show DT_LNK, and path traversal through symlinks works

## Capabilities

### New Capabilities

- `virtio-fs-symlink-stat`: O_STAT opens on symlinks return symlink attributes (S_IFLNK) instead of following to the target

### Modified Capabilities

- `virtio-fs-symlinks`: Update existing spec — FUSE_READLINK, FUSE_SYMLINK, and transparent following are already implemented; mark those requirements as done and add the O_STAT no-follow requirement

## Impact

- `nix/pkgs/system/virtio-fsd/src/scheme.rs` — `resolve_path`, `openat`
- VM test infrastructure — new functional test for symlink behavior through virtio-fs
