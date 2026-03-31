#!/usr/bin/env python3
"""Patch bootstrap to read /scheme/initfs/etc/init.env before exec'ing init.

The init binary reads INIT_LOG_LEVEL and INIT_SKIP from its process
environment before processing any unit files. Bootstrap builds the env
vector from the kernel's sys:env scheme and already hardcodes
RUST_BACKTRACE=1 and LD_LIBRARY_PATH.

This patch adds a read of an optional /scheme/initfs/etc/init.env file
after the initnsmgr is set up. Each KEY=VALUE line from the file is
pushed to the envs vector so init sees them in its environment.

If the file doesn't exist, bootstrap proceeds unchanged.
"""

import sys
import os


def patch_file(filepath, old, new):
    with open(filepath, "r") as f:
        content = f.read()
    if old not in content:
        print(f"WARNING: patch target not found in {filepath}")
        print(f"  Looking for: {repr(old[:100])}...")
        return False
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print(f"  Patched {filepath}")
    return True


def patch_exec(src_dir):
    exec_file = os.path.join(src_dir, "bootstrap/src/exec.rs")

    # 1. Add a stack buffer for the init.env file contents.
    #    Declared alongside env_bytes so both outlive envs (same scope level).
    #    Bootstrap's main() never returns (fexec replaces the process), so
    #    stack-local buffers effectively live forever.
    patch_file(
        exec_file,
        "    let mut env_bytes = [0_u8; 4096];",
        "    let mut env_bytes = [0_u8; 4096];\n"
        "    // Buffer for optional init.env file (init debug/skip config)\n"
        "    let mut init_env_buf = [0u8; 512];",
    )

    # 2. After initns_fd is available and before the CWD const, read the
    #    optional env file and push entries to envs.
    patch_file(
        exec_file,
        '    const CWD: &[u8] = b"/scheme/initfs";',
        '    // Read optional init env file for INIT_LOG_LEVEL, INIT_SKIP etc.\n'
        '    let init_env_len = match syscall::openat(\n'
        '        initns_fd.as_raw_fd(),\n'
        '        "/scheme/initfs/etc/init.env",\n'
        '        O_RDONLY | O_CLOEXEC,\n'
        '        0,\n'
        '    ) {\n'
        '        Ok(raw_fd) => {\n'
        '            let fd = FdGuard::new(raw_fd);\n'
        '            match fd.read(&mut init_env_buf) {\n'
        '                Ok(n) => n,\n'
        '                Err(_) => 0,\n'
        '            }\n'
        '        }\n'
        '        Err(_) => 0,\n'
        '    };\n'
        '    if init_env_len > 0 {\n'
        '        for line in init_env_buf[..init_env_len].split(|&c| c == b\'\\n\') {\n'
        '            if !line.is_empty() {\n'
        '                envs.push(line);\n'
        '            }\n'
        '        }\n'
        '    }\n'
        '\n'
        '    const CWD: &[u8] = b"/scheme/initfs";',
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <base-src-dir>")
        sys.exit(1)
    patch_exec(sys.argv[1])
