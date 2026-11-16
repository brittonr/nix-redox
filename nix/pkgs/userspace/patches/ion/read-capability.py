#!/usr/bin/env python3
"""Correct Ion read's TTY/capability distinction for the pinned shell sources.

liner f3fb3b7 uses termion 4.0.5, whose Redox raw-mode transport opens a
named `termios` duplicate of stdout before reading any stdin. debug: is a
TTY but does not provide that capability. Probe that same selector, not
libc's newer terminal ioctl protocol, and retain liner for real terminals.

The lock identities and complete old builtin are intentional fail-closed
anchors: a dependency/source update needs a fresh review of this boundary.
"""

from pathlib import Path
import sys
import tomllib


root = Path(sys.argv[1]) if len(sys.argv) == 2 else None
if root is None:
    raise SystemExit("usage: read-capability.py ION_SOURCE_ROOT")

manifest = tomllib.loads((root / "Cargo.toml").read_text())
if (manifest["package"]["name"], manifest["package"]["version"]) != (
    "ion-shell", "1.0.0-alpha"
):
    raise SystemExit("ion read capability: unsupported shell source version")

packages = tomllib.loads((root / "Cargo.lock").read_text())["package"]
for name, version, source in (
    (
        "redox_liner", "0.5.3",
        "git+https://gitlab.redox-os.org/redox-os/liner#f3fb3b754623026dca820cbf36231fa92772416f",
    ),
    ("termion", "4.0.5", "registry+https://github.com/rust-lang/crates.io-index"),
    ("libredox", "0.1.3", "registry+https://github.com/rust-lang/crates.io-index"),
    ("libc", "0.2.171", "registry+https://github.com/rust-lang/crates.io-index"),
):
    found = [p for p in packages if p["name"] == name]
    if len(found) != 1 or (found[0]["version"], found[0].get("source")) != (version, source):
        raise SystemExit(f"ion read capability: unsupported {name} dependency; review raw-mode API")

path = root / "src/lib/builtins/mod.rs"
text = path.read_text()
old = '''pub fn read(args: &[types::Str], shell: &mut Shell<'_>) -> Status {
    if atty::is(atty::Stream::Stdin) {
        let mut con = Context::new();
        for arg in args.iter().skip(1) {
            match con.read_line(Prompt::from(format!("{}=", arg.trim())), None, &mut EmptyCompleter)
            {
                Ok(buffer) => {
                    shell.variables_mut().set(arg.as_ref(), buffer.trim());
                }
                Err(_) => return Status::FALSE,
            }
        }
    } else {
        let stdin = io::stdin();
        let handle = stdin.lock();
        let mut lines = handle.lines();
        for arg in args.iter().skip(1) {
            if let Some(Ok(line)) = lines.next() {
                shell.variables_mut().set(arg.as_ref(), line.trim());
            }
        }
    }
    Status::SUCCESS
}'''
new = '''pub fn read(args: &[types::Str], shell: &mut Shell<'_>) -> Status {
    if args.len() < 2 {
        return Status::SUCCESS;
    }
    let line_editing = if atty::is(atty::Stream::Stdin) {
        match read_line_editing_supported() {
            Ok(supported) => supported,
            Err(error) => return Status::error(format!("ion: read: {}", error)),
        }
    } else {
        false
    };
    if line_editing {
        let mut con = Context::new();
        for arg in args.iter().skip(1) {
            match con.read_line(Prompt::from(format!("{}=", arg.trim())), None, &mut EmptyCompleter)
            {
                Ok(buffer) => {
                    shell.variables_mut().set(arg.as_ref(), buffer.trim());
                }
                // No fallback after liner starts: input may already have been
                // consumed. In particular, Ctrl-C and Ctrl-D remain failures.
                Err(_) => return Status::FALSE,
            }
        }
    } else {
        // Stdin's shared buffer preserves typeahead across builtin calls. Do
        // not use a subprocess or a fresh BufReader that drops unread bytes.
        let stdin = io::stdin();
        let handle = stdin.lock();
        let mut lines = handle.lines();
        for arg in args.iter().skip(1) {
            match lines.next() {
                Some(Ok(line)) => shell.variables_mut().set(arg.as_ref(), line.trim()),
                None => return Status::FALSE,
                Some(Err(error)) if error.kind() == io::ErrorKind::Interrupted => {
                    return Status::FALSE;
                }
                Some(Err(error)) => return Status::error(format!("ion: read: {}", error)),
            }
        }
    }
    Status::SUCCESS
}'''
helper = '''// This is the capability boundary used by pinned termion 4.0.5 on Redox:
// IntoRawMode first duplicates stdout with the selector "termios". Merely
// being a TTY (as debug: is) does not guarantee that selector is supported.
// Probe before liner can consume input, without changing terminal settings.
fn read_line_editing_supported() -> io::Result<bool> {
    #[cfg(target_os = "redox")]
    {
        // libredox 0.1.3 is already linked by termion. Its v1 calls return
        // either a value or a negated errno, not libc's -1/errno convention.
        extern "C" {
            fn redox_dup_v1(fd: usize, selector: *const u8, len: usize) -> usize;
            fn redox_close_v1(fd: usize) -> usize;
        }
        let selector = b"termios";
        let fd = unsafe {
            redox_dup_v1(nix::libc::STDOUT_FILENO as usize, selector.as_ptr(), selector.len())
        };
        if fd > usize::MAX - 4095 {
            let errno = fd.wrapping_neg() as i32;
            return match errno {
                nix::libc::ENOSYS | nix::libc::ENOTTY | nix::libc::EOPNOTSUPP => Ok(false),
                _ => Err(io::Error::from_raw_os_error(errno)),
            };
        }
        let result = unsafe { redox_close_v1(fd) };
        if result > usize::MAX - 4095 {
            return Err(io::Error::from_raw_os_error(result.wrapping_neg() as i32));
        }
    }
    Ok(true)
}

'''
anchor = '#[builtin(\n    desc = "read a line of input into some variables",'
if text.count(old) != 1 or text.count(anchor) != 1:
    raise SystemExit("ion read capability: expected exactly one original read builtin and attribute")
text = text.replace(old, new, 1).replace(anchor, helper + anchor, 1)
path.write_text(text)
