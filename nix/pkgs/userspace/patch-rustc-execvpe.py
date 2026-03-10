#!/usr/bin/env python3
"""
Patch Rust std to use execvpe() on Redox instead of environ + execvp().

Root cause: Rust std's do_exec() writes to the `environ` global, then
calls execvp(). On Redox, the global environ update doesn't reliably
reach relibc's internal reader, so env vars set via Command::env() are
lost in the child process.

Fix: On Redox, call execvpe(file, argv, envp) which passes the envp
directly to execve(), bypassing the global environ entirely.

This removes the --env-set workaround entirely — env vars propagate
through the native mechanism.

Patched files:
  library/std/src/sys/process/unix/unix.rs
"""

import sys
import os


def patch_do_exec(root_dir):
    """Patch do_exec to use execvpe on Redox."""
    path = os.path.join(root_dir, "library/std/src/sys/process/unix/unix.rs")
    if not os.path.exists(path):
        print(f"  ERROR: {path} not found")
        sys.exit(1)

    with open(path, 'r') as f:
        content = f.read()

    # Find the environ + execvp block in do_exec:
    #   _reset = Some(Reset(*sys::env::environ()));
    #   *sys::env::environ() = envp.as_ptr();
    # }
    # libc::execvp(...)
    old = '''        let mut _reset = None;
        if let Some(envp) = maybe_envp {
            struct Reset(*const *const libc::c_char);

            impl Drop for Reset {
                fn drop(&mut self) {
                    unsafe {
                        *sys::env::environ() = self.0;
                    }
                }
            }

            _reset = Some(Reset(*sys::env::environ()));
            *sys::env::environ() = envp.as_ptr();
        }

        libc::execvp(self.get_program_cstr().as_ptr(), self.get_argv().as_ptr());'''

    new = '''        // On Redox, updating the global `environ` pointer then calling
        // execvp() doesn't reliably propagate env vars to the child.
        // Use execvpe() which passes the envp directly to execve(),
        // bypassing the global environ entirely.
        #[cfg(target_os = "redox")]
        {
            if let Some(envp) = maybe_envp {
                unsafe extern "C" {
                    fn execvpe(
                        file: *const libc::c_char,
                        argv: *const *const libc::c_char,
                        envp: *const *const libc::c_char,
                    ) -> libc::c_int;
                }
                execvpe(
                    self.get_program_cstr().as_ptr(),
                    self.get_argv().as_ptr(),
                    envp.as_ptr(),
                );
            } else {
                libc::execvp(
                    self.get_program_cstr().as_ptr(),
                    self.get_argv().as_ptr(),
                );
            }
        }

        #[cfg(not(target_os = "redox"))]
        {
            let mut _reset = None;
            if let Some(envp) = maybe_envp {
                struct Reset(*const *const libc::c_char);

                impl Drop for Reset {
                    fn drop(&mut self) {
                        unsafe {
                            *sys::env::environ() = self.0;
                        }
                    }
                }

                _reset = Some(Reset(*sys::env::environ()));
                *sys::env::environ() = envp.as_ptr();
            }

            libc::execvp(self.get_program_cstr().as_ptr(), self.get_argv().as_ptr());
        }'''

    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: do_exec() uses execvpe() on Redox")
    else:
        print(f"  WARNING: Could not find environ+execvp pattern in unix.rs")
        print(f"  The code may have already been patched or the source differs.")
        return False

    with open(path, 'w') as f:
        f.write(content)
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <rust-source-dir>")
        sys.exit(1)

    root_dir = sys.argv[1]
    print("Patching Rust std: use execvpe() on Redox for env propagation...")
    if patch_do_exec(root_dir):
        print("Done! Env vars now propagate through exec() on Redox.")
    else:
        print("FAILED: No patches applied.")
        sys.exit(1)
