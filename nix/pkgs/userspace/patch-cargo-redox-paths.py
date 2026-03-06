#!/usr/bin/env python3
"""Patch Cargo to handle Redox file: URL paths.

On Redox OS, multiple sources produce paths with "file:" prefix:
1. std::fs::canonicalize() returns "file:/tmp/project/src/main.rs"
2. url::Url::to_file_path() returns "file:/tmp/vendor" for "file:///tmp/vendor"
3. Cargo's SourceId stores file:// URLs that get converted to paths

This patch:
1. Strips "file:" prefix in TargetSourcePath::From<PathBuf> (manifest.rs)
2. Adds a helper to normalize Redox paths in source_id.rs
3. Patches DirectorySource to strip file: prefix from root path
"""

import sys
import os

base = sys.argv[1] if len(sys.argv) > 1 else "."

# ============================================================
# Patch 1: manifest.rs — TargetSourcePath assertion
# ============================================================
manifest_path = os.path.join(base, "src/tools/cargo/src/cargo/core/manifest.rs")

with open(manifest_path, 'r') as f:
    content = f.read()

old = '''impl From<PathBuf> for TargetSourcePath {
    fn from(path: PathBuf) -> Self {
        assert!(path.is_absolute(), "`{}` is not absolute", path.display());
        TargetSourcePath::Path(path)
    }
}'''

new = '''impl From<PathBuf> for TargetSourcePath {
    fn from(path: PathBuf) -> Self {
        // On Redox OS, paths may have "file:" URL scheme prefix.
        // Strip it to get a standard absolute path.
        let path = crate::util::redox_strip_file_prefix(path);
        assert!(path.is_absolute(), "`{}` is not absolute", path.display());
        TargetSourcePath::Path(path)
    }
}'''

if old in content:
    content = content.replace(old, new)
    with open(manifest_path, 'w') as f:
        f.write(content)
    print(f"  Patched {manifest_path}: strip file: prefix in TargetSourcePath")
else:
    print(f"  ERROR: Could not find TargetSourcePath pattern in {manifest_path}")
    sys.exit(1)

# ============================================================
# Patch 2: Add redox_strip_file_prefix helper to cargo util
# ============================================================
# Add to src/tools/cargo/src/cargo/util/mod.rs
util_mod_path = os.path.join(base, "src/tools/cargo/src/cargo/util/mod.rs")

with open(util_mod_path, 'r') as f:
    util_content = f.read()

helper_code = '''
/// On Redox OS, various sources (canonicalize, URL to_file_path, etc.)
/// return paths with "file:" URL scheme prefix. Strip it.
pub fn redox_strip_file_prefix(path: std::path::PathBuf) -> std::path::PathBuf {
    let s = path.to_string_lossy();
    if s.starts_with("file:") {
        std::path::PathBuf::from(&s[5..])
    } else {
        path
    }
}
'''

if 'redox_strip_file_prefix' not in util_content:
    # Add at the end of the file
    util_content = util_content.rstrip() + '\n' + helper_code
    with open(util_mod_path, 'w') as f:
        f.write(util_content)
    print(f"  Patched {util_mod_path}: added redox_strip_file_prefix helper")

# ============================================================
# Patch 3: DirectorySource — strip file: from root path
# ============================================================
dir_src_path = os.path.join(base, "src/tools/cargo/src/cargo/sources/directory.rs")

with open(dir_src_path, 'r') as f:
    dir_content = f.read()

old_new = '''    pub fn new(path: &Path, id: SourceId, gctx: &'gctx GlobalContext) -> DirectorySource<'gctx> {
        DirectorySource {
            source_id: id,
            root: path.to_path_buf(),'''

new_new = '''    pub fn new(path: &Path, id: SourceId, gctx: &'gctx GlobalContext) -> DirectorySource<'gctx> {
        // On Redox OS, paths from URL conversion may have "file:" prefix
        let root = crate::util::redox_strip_file_prefix(path.to_path_buf());
        DirectorySource {
            source_id: id,
            root,'''

if old_new in dir_content:
    dir_content = dir_content.replace(old_new, new_new)
    with open(dir_src_path, 'w') as f:
        f.write(dir_content)
    print(f"  Patched {dir_src_path}: strip file: prefix from DirectorySource root")
else:
    print(f"  WARNING: Could not find DirectorySource::new pattern in {dir_src_path}")
    if "pub fn new" in dir_content:
        idx = dir_content.index("pub fn new")
        print(f"  Context: {dir_content[idx:idx+200]}")
    sys.exit(1)
