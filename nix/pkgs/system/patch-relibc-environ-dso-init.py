#!/usr/bin/env python3
"""Fix DSO environ propagation: broadcast environ to __relibc_init_environ.

Root cause:
  When ld_so loads a dynamically-linked binary, it calls run_init() for each
  DSO, writing platform::environ into the DSO's __relibc_init_environ symbol.
  But at that point, ld_so's own environ is NULL (the kernel envp hasn't been
  processed yet). Later, relibc_start_v1 sets platform::environ from the
  kernel's envp stack — but __relibc_init_environ is never updated.

  Result: DSOs have environ=NULL and __relibc_init_environ=NULL (via GLOB_DAT
  to main binary's copy, which was set to NULL by ld_so). Any code in a DSO
  that calls getenv() or reads environ directly gets NULL.

  This breaks option_env!("LD_LIBRARY_PATH") in rustc because librustc_driver.so
  is a DSO with its own relibc statics. The getenv fallback (from
  patch-relibc-dso-environ.py) reads __relibc_init_environ but finds NULL.

Fix:
  In relibc_start_v1, after setting platform::environ from envp, also update
  __relibc_init_environ to match. The DSO's getenv fallback reads
  __relibc_init_environ through a GLOB_DAT relocation that resolves to the
  main binary's copy. After this fix, it finds a valid environ pointer.

  Combined with the existing getenv self-init (patch-relibc-dso-environ.py),
  the first getenv() call from DSO code sets the DSO's local environ from
  the now-valid __relibc_init_environ. Subsequent direct environ reads also
  work because the DSO's local environ is no longer null.

Handles both test scenarios:
  - env-propagation-simple: basic cargo build with option_env!("LD_LIBRARY_PATH")
  - env-propagation-heavy: build.rs fork+exec 20 times then option_env!() check
    (fork+exec doesn't corrupt environ because each child gets fresh envp via
    execvpe, and the parent's environ pointer is not modified by fork)
"""
import sys

with open("src/start.rs", "r") as f:
    content = f.read()

# Match the environ setup block in relibc_start_v1, followed by the auxvs line.
# This block is NOT modified by other patches (environ-diag patches init_array,
# grow-main-stack patches the exit/main call at the end).
OLD = """\
    // We check for NULL here since ld.so might already have initialized it for us, and we don't
    // want to overwrite it if constructors in .init_array of dependency libraries have called
    // setenv.
    if unsafe { platform::environ }.is_null() {
        // Set up envp
        let envp = sp.envp();
        let mut len = 0;
        while !(unsafe { *envp.add(len) }).is_null() {
            len += 1;
        }
        unsafe { platform::OUR_ENVIRON.unsafe_set(copy_string_array(envp, len)) };
        unsafe { platform::environ = platform::OUR_ENVIRON.unsafe_mut().as_mut_ptr() };
    }

    let auxvs"""

NEW = """\
    // We check for NULL here since ld.so might already have initialized it for us, and we don't
    // want to overwrite it if constructors in .init_array of dependency libraries have called
    // setenv.
    if unsafe { platform::environ }.is_null() {
        // Set up envp
        let envp = sp.envp();
        let mut len = 0;
        while !(unsafe { *envp.add(len) }).is_null() {
            len += 1;
        }
        unsafe { platform::OUR_ENVIRON.unsafe_set(copy_string_array(envp, len)) };
        unsafe { platform::environ = platform::OUR_ENVIRON.unsafe_mut().as_mut_ptr() };
    }

    // Broadcast environ to DSOs: update __relibc_init_environ so that DSOs
    // can lazily initialize their local environ via the getenv() fallback.
    //
    // Timeline of the problem:
    //   1. ld_so loads DSOs and calls run_init() → writes its own environ
    //      (NULL at that point) into each DSO's __relibc_init_environ
    //   2. relibc_start_v1 (here) sets platform::environ from kernel envp
    //   3. __relibc_init_environ in the main binary is still NULL
    //   4. DSO getenv() fallback reads __relibc_init_environ via GLOB_DAT
    //      (resolves to main binary's copy) → NULL → fails
    //
    // Fix: write the now-valid environ pointer into __relibc_init_environ.
    // DSOs reference this symbol via GLOB_DAT, so they see the update.
    unsafe {
        __relibc_init_environ = platform::environ;
    }

    let auxvs"""

if OLD in content:
    content = content.replace(OLD, NEW)
    print("Patched relibc_start_v1: broadcast environ to __relibc_init_environ")
else:
    print("ERROR: could not find environ setup block in relibc_start_v1!")
    print("  Expected the envp setup block followed by 'let auxvs'")
    print("  Another patch may have modified this section.")
    sys.exit(1)

with open("src/start.rs", "w") as f:
    f.write(content)

print("Done: DSO environ propagation fix applied")
