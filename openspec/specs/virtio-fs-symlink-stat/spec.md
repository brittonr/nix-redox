## ADDED Requirements

### Requirement: O_STAT opens on symlinks do not follow the final component
When a path is opened with `O_STAT` and the final path component is a symlink, `resolve_path` SHALL return the symlink node's own nodeid and attributes (with `S_IFLNK` in the mode bits) without calling FUSE_READLINK on it. Intermediate symlinks in the path SHALL still be followed.

#### Scenario: lstat on a symlink through virtio-fs
- **WHEN** a symlink `/scheme/shared/link` points to `target.txt` and is opened with `O_STAT`
- **THEN** `fstat` returns `st_mode` with `S_IFLNK` type bits set
- **AND** the returned `st_size` reflects the symlink entry's size (not the target's)

#### Scenario: lstat on a regular file is unchanged
- **WHEN** a regular file `/scheme/shared/file.txt` is opened with `O_STAT`
- **THEN** `fstat` returns `st_mode` with `S_IFREG` type bits set (existing behavior, no change)

#### Scenario: Intermediate symlinks still followed for O_STAT
- **WHEN** `/scheme/shared/link-dir/file.txt` is opened with `O_STAT` where `link-dir` is a symlink to `real-dir`
- **THEN** the intermediate symlink `link-dir` is followed
- **AND** `fstat` returns attributes of `real-dir/file.txt`
