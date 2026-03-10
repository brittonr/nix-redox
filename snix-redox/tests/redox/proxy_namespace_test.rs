//! Kernel mechanism validation for per-path filesystem proxy.
//!
//! This test binary is cross-compiled for Redox and runs inside a VM.
//! It validates the core assumptions of the proxy sandbox:
//!
//! 1. Can we create a namespace WITHOUT file: via mkns?
//! 2. Can we register a userspace scheme named "file" in that namespace?
//! 3. Does a child process's file: operations route to our proxy?
//! 4. What's the IPC round-trip overhead?
//!
//! Run inside Redox:
//!   /nix/system/profile/bin/proxy_namespace_test
//!
//! Expected output: PASS/FAIL for each test.

// This file is a standalone test binary, not part of the library.
// It only compiles on Redox.

#[cfg(target_os = "redox")]
fn main() {
    println!("=== Per-path proxy namespace tests ===");
    println!();

    test_mkns_without_file();
    test_register_file_scheme_to_ns();
    // test_fork_setns_proxy() requires the full scheme handler
    // test_roundtrip_latency() requires the full scheme handler

    println!();
    println!("=== Done ===");
}

#[cfg(not(target_os = "redox"))]
fn main() {
    println!("This test only runs on Redox OS.");
    println!("Cross-compile with: cargo build --target x86_64-unknown-redox");
}

#[cfg(target_os = "redox")]
fn test_mkns_without_file() {
    use ioslice::IoSlice;

    print!("TEST 1: mkns without file: scheme... ");

    let schemes: Vec<&[u8]> = vec![
        b"memory",
        b"pipe",
        b"rand",
        b"null",
        b"zero",
    ];

    let io_slices: Vec<IoSlice> = schemes
        .iter()
        .map(|name| IoSlice::new(name))
        .collect();

    match libredox::call::mkns(&io_slices) {
        Ok(ns_fd) => {
            println!("PASS (ns_fd={})", ns_fd);
            // Don't close it yet — we'll use it in the next test.
            // Store in a static or thread-local for the next test.
            unsafe { CHILD_NS_FD = Some(ns_fd); }
        }
        Err(e) => {
            println!("FAIL: mkns returned error: {} (errno={})", e, e.errno());
            if e.errno() == libredox::errno::ENOSYS {
                println!("  → Kernel does not support mkns. Upgrade needed.");
            }
        }
    }
}

#[cfg(target_os = "redox")]
static mut CHILD_NS_FD: Option<usize> = None;

#[cfg(target_os = "redox")]
fn test_register_file_scheme_to_ns() {
    use redox_scheme::Socket;

    print!("TEST 2: register_scheme_to_ns(ns_fd, \"file\", cap_fd)... ");

    let child_ns_fd = match unsafe { CHILD_NS_FD } {
        Some(fd) => fd,
        None => {
            println!("SKIP (mkns failed in test 1)");
            return;
        }
    };

    // Create a scheme socket.
    let socket = match Socket::create() {
        Ok(s) => s,
        Err(e) => {
            println!("FAIL: Socket::create() failed: {}", e);
            return;
        }
    };

    // Get a capability fd from the socket.
    let cap_fd = match socket.create_this_scheme_fd(0, 0, 0, 0) {
        Ok(fd) => fd,
        Err(e) => {
            println!("FAIL: create_this_scheme_fd failed: {}", e);
            return;
        }
    };

    // Try to register "file" in the child namespace.
    match libredox::call::register_scheme_to_ns(child_ns_fd, "file", cap_fd) {
        Ok(()) => {
            println!("PASS");
            println!("  → Kernel accepts 'file' as a userspace scheme name in child namespace!");
            println!("  → This confirms the proxy approach is viable.");
        }
        Err(e) => {
            println!("FAIL: register_scheme_to_ns returned error: {} (errno={})", e, e.errno());
            if e.errno() == libredox::errno::EEXIST {
                println!("  → 'file' already exists in the namespace (expected — it's the kernel scheme).");
                println!("  → The child namespace was created WITHOUT file:, so this is unexpected.");
            } else if e.errno() == libredox::errno::EACCES {
                println!("  → Permission denied. May need elevated privileges.");
            } else if e.errno() == libredox::errno::ENOSYS {
                println!("  → Kernel does not support register_scheme_to_ns.");
            }
        }
    }
}
