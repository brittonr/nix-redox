//! boot-log-sink — register a file as a logd output sink.
//!
//! Opens a log file on the rootfs and sends the fd to logd via its
//! add_sink interface. logd backfills all buffered lines (up to 1000)
//! and continues forwarding new log output to the file.
//!
//! Intended to run as an early rootfs oneshot_async service so that
//! init debug output is available at /var/log/boot.log after login.
//!
//! Zero external dependencies — uses raw Redox syscalls via inline asm
//! to avoid vendoring redox_syscall or libredox crates.

use std::fs::{self, OpenOptions};
use std::os::fd::AsRawFd;

// Redox syscall numbers
const SYS_CLASS_FILE: usize = 0x2000_0000;
const SYS_ARG_SLICE: usize = 0x0100_0000;
const SYS_ARG_MSLICE: usize = 0x0200_0000;
const SYS_CALL: usize = SYS_CLASS_FILE | SYS_ARG_SLICE | SYS_ARG_MSLICE | 0xCA11;

// SYS_CALL flags (bitfield packed with metadata length)
const CALL_WRITE: usize = 1 << 9;
const CALL_FD: usize = 1 << 11;

#[cfg(target_os = "redox")]
unsafe fn syscall5(nr: usize, a: usize, b: usize, c: usize, d: usize, e: usize) -> usize {
    let ret: usize;
    // rbx is reserved by LLVM — save/restore around the syscall
    core::arch::asm!(
        "push rbx",
        "mov rbx, {a}",
        "int 0x80",
        "pop rbx",
        a = in(reg) a,
        inlateout("rax") nr => ret,
        in("rcx") b,
        in("rdx") c,
        in("rsi") d,
        in("rdi") e,
        options(nostack),
    );
    ret
}



/// Send an fd to a scheme via SYS_CALL with CALL_FD flag.
#[cfg(target_os = "redox")]
fn redox_sendfd(scheme_fd: usize, fd_to_send: usize) -> Result<usize, usize> {
    let payload = fd_to_send.to_ne_bytes();
    let flags_and_mlen = CALL_FD | CALL_WRITE; // metadata len = 0
    let ret = unsafe {
        syscall5(
            SYS_CALL,
            scheme_fd,
            payload.as_ptr() as usize,
            payload.len(),
            flags_and_mlen,
            core::ptr::null::<u64>() as usize,
        )
    };
    if ret > usize::MAX / 2 {
        Err(ret)
    } else {
        Ok(ret)
    }
}

#[cfg(not(target_os = "redox"))]
fn redox_sendfd(_scheme_fd: usize, _fd_to_send: usize) -> Result<usize, usize> {
    Err(1)
}

fn main() {
    let log_path = std::env::args().nth(1).unwrap_or_else(|| "/var/log/boot.log".to_string());

    // Ensure parent directory exists
    if let Some(parent) = std::path::Path::new(&log_path).parent() {
        let _ = fs::create_dir_all(parent);
    }

    // Open the log file for writing (truncate on each boot)
    let file = match OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&log_path)
    {
        Ok(f) => f,
        Err(e) => {
            eprintln!("boot-log-sink: failed to open {}: {}", log_path, e);
            std::process::exit(1);
        }
    };
    let file_fd = file.as_raw_fd() as usize;

    // Open logd's add_sink handle via std::fs (uses relibc's namespace fd)
    let add_sink = match OpenOptions::new()
        .write(true)
        .open("/scheme/log/add_sink")
    {
        Ok(f) => f,
        Err(e) => {
            eprintln!("boot-log-sink: failed to open /scheme/log/add_sink: {}", e);
            std::process::exit(1);
        }
    };
    let add_sink_fd = add_sink.as_raw_fd() as usize;

    // Send the file fd to logd — logd will backfill buffered lines
    // and continue writing new log output to this fd.
    match redox_sendfd(add_sink_fd, file_fd) {
        Ok(_) => eprintln!("boot-log-sink: registered {} as log sink", log_path),
        Err(e) => {
            eprintln!("boot-log-sink: sendfd failed: error {}", e);
            std::process::exit(1);
        }
    }

    // fd is now duplicated in logd's process — we can exit.
    // logd keeps writing to the file until shutdown.
}
