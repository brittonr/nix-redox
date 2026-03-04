#!/usr/bin/env python3
"""
Patch rustc's linker invocation to avoid pipe-based output capture on Redox.

Rust std's Command::output() uses poll() to read from piped stdout/stderr.
On Redox OS, poll() has a bug that causes a crash (Invalid opcode / ud2)
when the child process runs for more than trivial time.

Fix: Patch the Command::output() wrapper in rustc_codegen_ssa/src/back/command.rs
to use Stdio::inherit() + status() instead of output(). This routes linker
output directly to the terminal and avoids poll()-based pipe reading entirely.

Also patches link.rs to avoid the direct Stdio::piped() spawn path.
"""

import sys
import os

def patch_command_rs(path):
    """Patch command.rs: Command::output() → use inherited stdio."""
    with open(path, 'r') as f:
        content = f.read()

    original = content

    # The output() method currently does:
    #   pub(crate) fn output(&mut self) -> io::Result<Output> {
    #       self.command().output()
    #   }
    # Change to: use inherited stdio and status() to avoid poll()-based pipe reading
    old = '''    pub(crate) fn output(&mut self) -> io::Result<Output> {
        self.command().output()
    }'''
    new = '''    pub(crate) fn output(&mut self) -> io::Result<Output> {
        // On Redox, poll() crashes when reading from piped child processes.
        // Use inherited stdio (linker output goes to terminal) and status()
        // to avoid triggering Rust std's read2()/poll() code path.
        let status = self.command()
            .stdout(process::Stdio::inherit())
            .stderr(process::Stdio::inherit())
            .status()?;
        Ok(Output { status, stdout: Vec::new(), stderr: Vec::new() })
    }'''

    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: Command::output() in command.rs")
    else:
        print(f"  WARNING: Command::output() pattern not found in command.rs")
        return False

    with open(path, 'w') as f:
        f.write(content)
    return True

def patch_link_rs(path):
    """Patch link.rs: primary spawn path to also avoid pipes."""
    with open(path, 'r') as f:
        content = f.read()

    original = content
    patched = False

    # Patch the primary spawn path: Stdio::piped → Stdio::inherit
    old = 'cmd.command().stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()'
    new = 'cmd.command().stdout(Stdio::inherit()).stderr(Stdio::inherit()).spawn()'
    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: primary spawn (Stdio::piped → Stdio::inherit)")
        patched = True

    # Patch wait_with_output → wait + construct Output
    # Note: child.wait() requires mut, so add 'mut' to the binding
    old = 'let output = child.wait_with_output();'
    new = ('let output = child.wait().map(|status| '
           'std::process::Output { status, stdout: Vec::new(), stderr: Vec::new() });')
    # Also need to make child mut
    content = content.replace('Ok(child) =>', 'Ok(mut child) =>')
    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: wait_with_output → wait + Output")
        patched = True

    if patched:
        with open(path, 'w') as f:
            f.write(content)
    return patched

def main():
    if len(sys.argv) < 2:
        print("Usage: patch-rustc-linker-pipes.py <rust-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]
    command_rs = os.path.join(src_dir, 'compiler', 'rustc_codegen_ssa', 'src', 'back', 'command.rs')
    link_rs = os.path.join(src_dir, 'compiler', 'rustc_codegen_ssa', 'src', 'back', 'link.rs')

    ok = True
    if os.path.exists(command_rs):
        print(f"Patching {command_rs}...")
        ok = patch_command_rs(command_rs) and ok
    else:
        print(f"ERROR: {command_rs} not found")
        ok = False

    if os.path.exists(link_rs):
        print(f"Patching {link_rs}...")
        ok = patch_link_rs(link_rs) and ok
    else:
        print(f"ERROR: {link_rs} not found")
        ok = False

    if ok:
        print("Done! Linker invocation will use inherited stdio (no pipes).")
    else:
        print("WARNING: Some patches failed!")
        sys.exit(1)

if __name__ == '__main__':
    main()
