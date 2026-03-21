## 1. Core: O_STAT no-follow for symlinks

- [x] 1.1 Add `follow_last: bool` parameter to `resolve_path_hops` in `scheme.rs`
- [x] 1.2 Update `resolve_path` to pass `follow_last: true` (preserves existing behavior)
- [x] 1.3 In `openat`, when `O_STAT` is set, call `resolve_path_hops` with `follow_last: false`
- [x] 1.4 Verify `fstat` returns S_IFLNK mode bits from the handle's cached/refreshed attributes (no fstat changes needed)

## 2. VM Functional Test

- [x] 2.1 Create host-side test directory with symlinks (file symlink, directory symlink, two-hop chain) in the bridge shared dir setup
- [x] 2.2 Write guest-side test script that reads through symlinks, stats them with O_STAT, and lists directories
- [x] 2.3 Run VM test end-to-end: build image, boot, execute test, verify PASS output on serial
