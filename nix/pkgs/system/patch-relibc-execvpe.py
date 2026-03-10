#!/usr/bin/env python3
"""
Add execvpe() to relibc — PATH search with explicit envp.

On Redox, Rust std's do_exec() updates the global `environ` pointer
then calls execvp(). But the global pointer update doesn't reliably
reach relibc's internal `platform::environ` read in execv(). The env
vars are lost between parent and child.

execvpe() is the GNU extension that takes (file, argv, envp) — it does
the same PATH search as execvp but passes the explicit envp through to
execve(), bypassing the global environ entirely.

This patch adds:
1. execvpe() in relibc's unistd module
2. Sys::execvpe() in the PAL trait
3. Platform implementations for Redox and Linux
"""

import sys
import os


def patch_unistd(root_dir):
    """Add execvpe() function to src/header/unistd/mod.rs."""
    path = os.path.join(root_dir, "src/header/unistd/mod.rs")
    if not os.path.exists(path):
        print(f"  ERROR: {path} not found")
        sys.exit(1)

    with open(path, 'r') as f:
        content = f.read()

    # Add execvpe right after execvp. Find the end of execvp by locating
    # the next function (fchdir).
    marker = '/// See <https://pubs.opengroup.org/onlinepubs/9799919799/functions/fchdir.html>.'
    if marker not in content:
        print(f"  ERROR: Could not find fchdir marker in unistd/mod.rs")
        sys.exit(1)

    if 'fn execvpe(' in content:
        print(f"  SKIP: execvpe already present in unistd/mod.rs")
        return True

    execvpe_fn = '''/// execvpe — execute a file with PATH search and explicit envp.
///
/// GNU extension. Like execvp but takes an explicit environment
/// array instead of using the global `environ`. This avoids the
/// race/visibility bug on Redox where updating the global environ
/// pointer from Rust std doesn't reach relibc's execv() reader.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn execvpe(
    file: *const c_char,
    argv: *const *mut c_char,
    envp: *const *mut c_char,
) -> c_int {
    let file = unsafe { CStr::from_ptr(file) };

    if file.to_bytes().contains(&b'/')
        || (cfg!(target_os = "redox") && file.to_bytes().contains(&b':'))
    {
        // Absolute or scheme path — call execve directly with explicit envp.
        unsafe { execve(file.as_ptr(), argv, envp) }
    } else {
        let mut error = errno::ENOENT;

        // Search PATH for the executable. Use the envp array to find PATH,
        // not the global environ (which may be stale).
        let path_val = unsafe { find_in_envp(envp, b"PATH") };
        if let Some(path_env) = path_val {
            for path in path_env.split(|b| *b == PATH_SEPARATOR) {
                let file_bytes = file.to_bytes();
                let length = file_bytes.len() + path.len() + 2;
                let mut program = alloc::vec::Vec::with_capacity(length);
                program.extend_from_slice(path);
                program.push(b'/');
                program.extend_from_slice(file_bytes);
                program.push(b'\\0');

                let program_c = CStr::from_bytes_with_nul(&program).unwrap();
                unsafe { execve(program_c.as_ptr(), argv, envp) };

                match platform::ERRNO.get() {
                    errno::ENOENT => (),
                    other => error = other,
                }
            }
        }

        platform::ERRNO.set(error);
        -1
    }
}

/// Search an envp array for a variable by name. Returns a slice of the
/// value (after the '=') or None if not found.
unsafe fn find_in_envp<'a>(envp: *const *mut c_char, name: &[u8]) -> Option<&'a [u8]> {
    if envp.is_null() {
        return None;
    }
    let mut ptr = envp;
    while !unsafe { (*ptr).is_null() } {
        let entry = unsafe { *ptr } as *const u8;
        // Compute string length manually (avoids cross-module strlen import).
        let mut len = 0usize;
        while unsafe { *entry.add(len) } != 0 {
            len += 1;
        }
        let entry_bytes = unsafe { core::slice::from_raw_parts(entry, len) };
        // Check if entry starts with "name="
        if entry_bytes.len() > name.len()
            && entry_bytes[..name.len()] == *name
            && entry_bytes[name.len()] == b'='
        {
            return Some(&entry_bytes[name.len() + 1..]);
        }
        ptr = unsafe { ptr.add(1) };
    }
    None
}

'''

    content = content.replace(marker, execvpe_fn + marker)

    with open(path, 'w') as f:
        f.write(content)

    print(f"  Patched: added execvpe() and find_in_envp() to unistd/mod.rs")
    return True


if __name__ == "__main__":
    root_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    print("Patching relibc: adding execvpe() (PATH search with explicit envp)...")
    patch_unistd(root_dir)
    print("Done!")
