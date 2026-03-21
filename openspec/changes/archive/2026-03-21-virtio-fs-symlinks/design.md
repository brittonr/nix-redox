## Context

The virtio-fsd scheme driver already implements FUSE_READLINK, FUSE_SYMLINK, transparent symlink following in `resolve_path`, and DT_LNK reporting in `getdents`. The one remaining gap: `resolve_path` always follows the final component's symlink, even for O_STAT opens. This means `lstat()` / `symlink_metadata()` on a symlink through virtio-fs returns the target's attributes instead of the link's — breaking symlink detection in snix (NAR hashing, profile management, GC roots).

## Goals / Non-Goals

**Goals:**
- O_STAT opens return the symlink node's own attributes (S_IFLNK in st_mode)
- All existing symlink-following behavior for non-O_STAT opens remains unchanged
- VM functional test proves end-to-end symlink behavior through the build bridge

**Non-Goals:**
- O_NOFOLLOW flag support (Redox doesn't have it in the flag set)
- Symlink creation through the scheme's `openat` (FUSE_SYMLINK is available but not needed from the scheme interface — snix creates symlinks via `std::os::unix::fs::symlink` on redoxfs, not through virtio-fs)
- Relative symlink rebase (symlink targets are stored verbatim)

## Decisions

**1. Add `follow_last` parameter to `resolve_path_hops`**

The existing `resolve_path` calls `resolve_path_hops(path, 40)` which always follows every symlink including the last. Add a `follow_last: bool` parameter. When false, the final component lookup returns the symlink's own entry (nodeid + attributes with S_IFLNK mode) without calling FUSE_READLINK.

Alternative considered: separate `resolve_path_lstat` method. Rejected — duplicates the entire path walk logic. A single boolean parameter keeps the code DRY.

**2. O_STAT triggers no-follow on the final component**

In `openat`, when `flags & O_STAT == O_STAT`, call `resolve_path` with `follow_last: false`. The handle is then created with the symlink's nodeid and attributes. `fstat` on this handle returns S_IFLNK mode bits from the cached (and getattr-refreshed) attributes — no special fstat changes needed.

**3. VM test uses host-created symlinks through virtio-fs**

The test creates a directory on the host side with symlinks, shares it via virtiofsd, and verifies from the Redox guest that: (a) reading through a symlink reaches the target, (b) stat on the symlink reports S_IFLNK, (c) directory listing shows DT_LNK type. This tests the full stack: FUSE protocol, virtio transport, scheme translation.

## Risks / Trade-offs

**[Risk] FUSE LOOKUP on symlinks returns entry with S_IFLNK but the nodeid might still refer to the target after virtiofsd auto-follows** → Mitigation: virtiofsd with `--cache=never` returns the raw symlink entry from LOOKUP. The S_IFLNK check in `resolve_path_hops` already detects this correctly — we just stop before calling readlink when `follow_last` is false and we're at the final component.

**[Risk] Symlink in intermediate path component + O_STAT** → Only the FINAL component is affected by `follow_last`. Intermediate symlinks are always followed, which is correct POSIX behavior.
