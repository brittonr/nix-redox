#!/usr/bin/env python3
"""Patch Rust std to strip 'file:' prefix from OS-returned paths on Redox.

On Redox OS, libc::realpath() and libc::getcwd() return paths with a "file:"
URL scheme prefix (e.g., "file:/tmp/hello"). This breaks Path::is_absolute()
and Path::join() throughout Rust code (including cargo).

Fix: Strip "file:" prefix in canonicalize() and getcwd() on Redox.
"""

import sys
import os

base = sys.argv[1] if len(sys.argv) > 1 else "."

# ============================================================
# Patch 1: canonicalize() in library/std/src/sys/fs/unix.rs
# ============================================================
fs_path = os.path.join(base, "library/std/src/sys/fs/unix.rs")

with open(fs_path, 'r') as f:
    content = f.read()

old_canonicalize = '''pub fn canonicalize(path: &CStr) -> io::Result<PathBuf> {
    let r = unsafe { libc::realpath(path.as_ptr(), ptr::null_mut()) };
    if r.is_null() {
        return Err(io::Error::last_os_error());
    }
    Ok(PathBuf::from(OsString::from_vec(unsafe {
        let buf = CStr::from_ptr(r).to_bytes().to_vec();
        libc::free(r as *mut _);
        buf
    })))
}'''

new_canonicalize = '''pub fn canonicalize(path: &CStr) -> io::Result<PathBuf> {
    let r = unsafe { libc::realpath(path.as_ptr(), ptr::null_mut()) };
    if r.is_null() {
        return Err(io::Error::last_os_error());
    }
    let path_buf = PathBuf::from(OsString::from_vec(unsafe {
        let buf = CStr::from_ptr(r).to_bytes().to_vec();
        libc::free(r as *mut _);
        buf
    }));
    // On Redox OS, realpath() returns paths with "file:" URL scheme prefix
    // (e.g., "file:/tmp/hello"). Strip it to get a standard absolute path.
    #[cfg(target_os = "redox")]
    {
        let s = path_buf.to_string_lossy();
        if s.starts_with("file:") {
            return Ok(PathBuf::from(&s[5..]));
        }
    }
    Ok(path_buf)
}'''

if old_canonicalize in content:
    content = content.replace(old_canonicalize, new_canonicalize)
    with open(fs_path, 'w') as f:
        f.write(content)
    print(f"  Patched {fs_path}: strip file: prefix in canonicalize()")
else:
    print(f"  WARNING: Could not find canonicalize pattern in {fs_path}")
    sys.exit(1)

# ============================================================
# Patch 2: getcwd() in library/std/src/sys/pal/unix/os.rs
# Target the non-espidf version (has the actual getcwd implementation)
# ============================================================
os_path = os.path.join(base, "library/std/src/sys/pal/unix/os.rs")

with open(os_path, 'r') as f:
    os_content = f.read()

# Find the NON-espidf getcwd: look for #[cfg(not(target_os = "espidf"))]
# followed by pub fn getcwd()
marker = '#[cfg(not(target_os = "espidf"))]\npub fn getcwd() -> io::Result<PathBuf> {'
if marker not in os_content:
    # Try with different whitespace
    marker = '#[cfg(not(target_os = "espidf"))]\npub fn getcwd() -> io::Result<PathBuf> {'

if marker in os_content:
    # Find the start of the function (after the cfg attribute)
    marker_pos = os_content.index(marker)
    fn_start = os_content.index('pub fn getcwd()', marker_pos)

    # Find matching closing brace
    brace_count = 0
    end_pos = fn_start
    for i in range(fn_start, len(os_content)):
        if os_content[i] == '{':
            brace_count += 1
        elif os_content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                end_pos = i
                break

    # Extract original function body (between first { and closing })
    first_brace = os_content.index('{', fn_start)
    original_body = os_content[first_brace+1:end_pos]

    # Build new function with inner function and Redox post-processing
    new_fn = 'pub fn getcwd() -> io::Result<PathBuf> {\n'
    new_fn += '    fn getcwd_raw() -> io::Result<PathBuf> {\n'
    new_fn += original_body
    new_fn += '    }\n'
    new_fn += '    let result = getcwd_raw()?;\n'
    new_fn += '    // On Redox OS, getcwd() returns paths with "file:" URL scheme prefix.\n'
    new_fn += '    // Strip it to get a standard absolute path.\n'
    new_fn += '    #[cfg(target_os = "redox")]\n'
    new_fn += '    {\n'
    new_fn += '        let s = result.to_string_lossy();\n'
    new_fn += '        if s.starts_with("file:") {\n'
    new_fn += '            return Ok(PathBuf::from(&s[5..]));\n'
    new_fn += '        }\n'
    new_fn += '    }\n'
    new_fn += '    Ok(result)\n'
    new_fn += '}'

    os_content = os_content[:fn_start] + new_fn + os_content[end_pos+1:]

    with open(os_path, 'w') as f:
        f.write(os_content)
    print(f"  Patched {os_path}: strip file: prefix in getcwd()")
else:
    print(f"  WARNING: Could not find non-espidf getcwd in {os_path}")
    print(f"  Looking for the marker pattern...")
    for variant in [
        '#[cfg(not(target_os = "espidf"))]',
        'pub fn getcwd() -> io::Result<PathBuf>',
    ]:
        if variant in os_content:
            idx = os_content.index(variant)
            print(f"  Found '{variant}' at position {idx}")
            print(f"  Context: ...{os_content[idx:idx+100]}...")
    sys.exit(1)

print("  All std path patches applied successfully")
