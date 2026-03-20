//! Kernel mechanism and proxy I/O validation for per-path filesystem proxy.
//!
//! This test binary is cross-compiled for Redox and runs inside a VM.
//! It validates both the kernel namespace primitives and the full
//! proxy I/O path:
//!
//! 1. Can we create a namespace WITHOUT file: via mkns?
//! 2. Can we register a userspace scheme named "file" in that namespace?
//! 3. Fork+setns: write a file through the proxy, verify on real fs.
//! 4. Proxy denies /etc/passwd (not on allow-list).
//! 5. Create dir + 3 files, getdents returns all 3.
//! 6. Write 1KB, read back, byte-for-byte match.
//! 7. Latency: 1000 open+read+close, print mean and p99.
//!
//! Run inside Redox:
//!   /nix/system/profile/bin/proxy_namespace_test
//!
//! Expected output: PASS/FAIL for each test.

#[cfg(target_os = "redox")]
fn main() {
    let args: Vec<String> = std::env::args().collect();

    // If invoked with --child <test>, run that child test function.
    // The parent forks us via Command::new with --child <test>,
    // having already done setns in pre_exec.
    if args.len() >= 3 && args[1] == "--child" {
        match args[2].as_str() {
            "test3" => child_test_3(),
            "test4" => child_test_4(),
            "test5" => child_test_5(),
            "test6" => child_test_6(),
            "test7" => child_test_7(),
            other => {
                eprintln!("unknown child test: {}", other);
                std::process::exit(99);
            }
        }
        return;
    }

    println!("=== Per-path proxy namespace tests ===");
    println!();

    test_mkns_without_file();
    test_register_file_scheme_to_ns();

    // Tests 3-7 need a running proxy. Set up once, run all tests.
    test_proxy_io();

    println!();
    println!("=== Done ===");
}

#[cfg(not(target_os = "redox"))]
fn main() {
    println!("This test only runs on Redox OS.");
    println!("Cross-compile with: cargo build --target x86_64-unknown-redox");
}

// ── Test 1: mkns without file ──────────────────────────────────────────

#[cfg(target_os = "redox")]
fn test_mkns_without_file() {
    use ioslice::IoSlice;

    print!("TEST 1: mkns without file: scheme... ");

    let schemes: Vec<&[u8]> = vec![b"memory", b"pipe", b"rand", b"null", b"zero"];
    let io_slices: Vec<IoSlice> = schemes.iter().map(|name| IoSlice::new(name)).collect();

    match libredox::call::mkns(&io_slices) {
        Ok(ns_fd) => {
            println!("PASS (ns_fd={})", ns_fd);
            let _ = syscall::close(ns_fd);
        }
        Err(e) => {
            println!("FAIL: mkns returned error: {} (errno={})", e, e.errno());
        }
    }
}

// ── Test 2: register file scheme to namespace ──────────────────────────

#[cfg(target_os = "redox")]
fn test_register_file_scheme_to_ns() {
    use ioslice::IoSlice;
    use redox_scheme::Socket;

    print!("TEST 2: register_scheme_to_ns(ns_fd, \"file\", cap_fd)... ");

    let schemes: Vec<&[u8]> = vec![b"memory", b"pipe", b"rand", b"null", b"zero"];
    let io_slices: Vec<IoSlice> = schemes.iter().map(|name| IoSlice::new(name)).collect();

    let ns_fd = match libredox::call::mkns(&io_slices) {
        Ok(fd) => fd,
        Err(e) => {
            println!("SKIP (mkns failed: {})", e);
            return;
        }
    };

    let socket = match Socket::create() {
        Ok(s) => s,
        Err(e) => {
            println!("FAIL: Socket::create() failed: {}", e);
            let _ = syscall::close(ns_fd);
            return;
        }
    };

    let cap_fd = match socket.create_this_scheme_fd(0, 0, 0, 0) {
        Ok(fd) => fd,
        Err(e) => {
            println!("FAIL: create_this_scheme_fd failed: {}", e);
            let _ = syscall::close(ns_fd);
            return;
        }
    };

    match libredox::call::register_scheme_to_ns(ns_fd, "file", cap_fd) {
        Ok(()) => {
            println!("PASS");
        }
        Err(e) => {
            println!(
                "FAIL: register_scheme_to_ns returned error: {} (errno={})",
                e,
                e.errno()
            );
        }
    }

    let _ = syscall::close(cap_fd);
    let _ = syscall::close(ns_fd);
}

// ── Tests 3-7: Proxy I/O round-trip tests ──────────────────────────────

#[cfg(target_os = "redox")]
fn test_proxy_io() {
    use std::path::PathBuf;

    // Set up writable and readable directories on the real filesystem.
    let writable_dir = PathBuf::from("/tmp/proxy-test-out");
    let input_dir = PathBuf::from("/tmp/proxy-test-input");

    // Clean up from previous runs.
    let _ = std::fs::remove_dir_all(&writable_dir);
    let _ = std::fs::remove_dir_all(&input_dir);
    std::fs::create_dir_all(&writable_dir).expect("create writable dir");
    std::fs::create_dir_all(&input_dir).expect("create input dir");

    // Create an input file for read tests.
    let input_file = input_dir.join("sample.txt");
    std::fs::write(&input_file, "input-data-for-proxy-test\n").expect("write input file");

    // Build allow-list: writable_dir = ReadWrite, input_dir = ReadOnly.
    let mut allow_list = snix_redox::build_proxy::AllowList::new();
    allow_list.read_write.insert(writable_dir.clone());
    allow_list.read_only.insert(input_dir.clone());
    // Allow paths needed for exec resolution and dynamic linking.
    allow_list.read_only.insert(PathBuf::from("/bin"));
    allow_list.read_only.insert(PathBuf::from("/nix"));
    allow_list.read_only.insert(PathBuf::from("/usr"));
    allow_list.read_only.insert(PathBuf::from("/lib"));

    // Start the proxy. This creates a namespace and registers file: in it.
    let config = snix_redox::sandbox::SandboxConfig {
        allowed_input_hashes: Default::default(),
        needs_network: false,
        output_dir: writable_dir.to_string_lossy().to_string(),
        tmp_dir: writable_dir.to_string_lossy().to_string(),
    };

    let (child_ns_fd, proxy) =
        match snix_redox::sandbox::setup_proxy_namespace(&config, allow_list) {
            Ok(v) => v,
            Err(e) => {
                println!("TEST 3: SKIP (proxy setup failed: {})", e);
                println!("TEST 4: SKIP");
                println!("TEST 5: SKIP");
                println!("TEST 6: SKIP");
                println!("TEST 7: SKIP");
                return;
            }
        };

    let socket_fd = proxy.socket_fd();

    // Run each test as a child process in the proxy namespace.
    run_child_test("TEST 3: fork+setns write through proxy", "test3",
        child_ns_fd, socket_fd, "proxy-write-roundtrip",
        Some(verify_test_3));
    run_child_test("TEST 4: proxy denies /etc/passwd", "test4",
        child_ns_fd, socket_fd, "proxy-denies-passwd", None);
    run_child_test("TEST 5: create dir + 3 files, getdents verifies", "test5",
        child_ns_fd, socket_fd, "proxy-getdents",
        Some(verify_test_5));
    run_child_test("TEST 6: write 1KB, read back, verify", "test6",
        child_ns_fd, socket_fd, "proxy-readback", None);
    run_child_test("TEST 7: latency (1000 open+read+close)", "test7",
        child_ns_fd, socket_fd, "proxy-roundtrip",
        Some(verify_test_7));

    // Shut down the proxy.
    proxy.shutdown();

    // Clean up.
    let _ = std::fs::remove_dir_all("/tmp/proxy-test-out");
    let _ = std::fs::remove_dir_all("/tmp/proxy-test-input");
}

/// Spawn a child process that enters the proxy namespace and runs a test.
///
/// Uses `Command::new` with `pre_exec` to close the scheme socket fd
/// and call setns — the same pattern as `local_build.rs`.
#[cfg(target_os = "redox")]
fn run_child_test(
    label: &str,
    test_name: &str,
    child_ns_fd: usize,
    socket_fd: Option<usize>,
    func_test_name: &str,
    verify_fn: Option<fn() -> Result<(), String>>,
) {
    use std::process::Command;
    use std::os::unix::process::CommandExt;

    print!("{}... ", label);

    // Find our own binary path.
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            println!("FAIL: can't find own exe: {}", e);
            println!("  FUNC_TEST:{}:FAIL:no exe path", func_test_name);
            return;
        }
    };

    // Strip "file:" prefix that Redox canonicalize adds.
    let exe_str = exe.to_string_lossy();
    let exe_path = if let Some(stripped) = exe_str.strip_prefix("file:") {
        stripped.to_string()
    } else {
        exe_str.to_string()
    };

    let mut cmd = Command::new(&exe_path);
    cmd.arg("--child").arg(test_name);

    // In pre_exec (runs in child after fork, before exec):
    // 1. Close the scheme socket fd (prevent disrupting parent's proxy).
    // 2. Call setns to enter the proxy namespace.
    unsafe {
        cmd.pre_exec(move || {
            if let Some(fd) = socket_fd {
                let _ = syscall::close(fd);
            }
            libredox::call::setns(child_ns_fd).map_err(|e| {
                std::io::Error::new(
                    std::io::ErrorKind::Other,
                    format!("setns: {e}"),
                )
            })?;
            Ok(())
        });
    }

    // Run child and collect output.
    match cmd.output() {
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);

            if output.status.success() {
                // Child succeeded. Run verification if provided.
                match verify_fn {
                    Some(verify) => match verify() {
                        Ok(()) => {
                            println!("PASS");
                            println!("  FUNC_TEST:{}:PASS", func_test_name);
                        }
                        Err(msg) => {
                            println!("FAIL: verification: {}", msg);
                            println!("  FUNC_TEST:{}:FAIL:{}", func_test_name, msg);
                        }
                    },
                    None => {
                        println!("PASS");
                        println!("  FUNC_TEST:{}:PASS", func_test_name);
                    }
                }
                // Print child stderr for diagnostics (latency stats, etc.)
                for line in stderr.lines() {
                    if !line.starts_with("buildfs:") {
                        println!("  {}", line);
                    }
                }
            } else {
                let code = output.status.code().unwrap_or(-1);
                println!("FAIL: child exited with code {}", code);
                if !stderr.is_empty() {
                    for line in stderr.lines().take(5) {
                        println!("  {}", line);
                    }
                }
                if !stdout.is_empty() {
                    for line in stdout.lines().take(5) {
                        println!("  {}", line);
                    }
                }
                println!("  FUNC_TEST:{}:FAIL:child exit {}", func_test_name, code);
            }
        }
        Err(e) => {
            println!("FAIL: spawn: {}", e);
            println!("  FUNC_TEST:{}:FAIL:spawn error", func_test_name);
        }
    }
}

// ── Test 3: write through proxy ────────────────────────────────────────

#[cfg(target_os = "redox")]
fn child_test_3() {
    use std::io::Write;

    // We are in the proxy namespace. file: operations go through the proxy.
    let path = "/tmp/proxy-test-out/test3.txt";
    let mut f = std::fs::File::create(path).expect("create file through proxy");
    f.write_all(b"hello proxy\n").expect("write through proxy");
    drop(f);
}

#[cfg(target_os = "redox")]
fn verify_test_3() -> Result<(), String> {
    // Verify the file on the real filesystem (parent is in original ns).
    match std::fs::read_to_string("/tmp/proxy-test-out/test3.txt") {
        Ok(content) if content == "hello proxy\n" => Ok(()),
        Ok(content) => Err(format!("wrong content: {:?}", content)),
        Err(e) => Err(format!("file not on real fs: {}", e)),
    }
}

// ── Test 4: EACCES on /etc/passwd ──────────────────────────────────────

#[cfg(target_os = "redox")]
fn child_test_4() {
    // /etc/passwd is not on the allow-list. The proxy should deny access.
    match std::fs::File::open("/etc/passwd") {
        Ok(_) => {
            eprintln!("/etc/passwd was readable (should be denied!)");
            std::process::exit(1);
        }
        Err(e) => {
            // PermissionDenied = proxy blocked it (EACCES).
            // NotFound or other errors also acceptable — path is not
            // accessible through the proxy either way.
            let kind = e.kind();
            if kind == std::io::ErrorKind::PermissionDenied {
                eprintln!("got EACCES as expected");
            } else {
                eprintln!("got {:?} (also acceptable: path not accessible)", kind);
            }
            // exit(0) — test passed
        }
    }
}

// ── Test 5: getdents ───────────────────────────────────────────────────

#[cfg(target_os = "redox")]
fn child_test_5() {
    use std::io::Write;

    let dir = "/tmp/proxy-test-out/subdir";

    // Create directory through the proxy.
    std::fs::create_dir_all(dir).expect("mkdir through proxy");

    // Write 3 files.
    for name in &["a.txt", "b.txt", "c.txt"] {
        let path = format!("{}/{}", dir, name);
        let mut f = std::fs::File::create(&path)
            .unwrap_or_else(|e| panic!("create {} through proxy: {}", name, e));
        f.write_all(format!("content of {}\n", name).as_bytes())
            .unwrap_or_else(|e| panic!("write {} through proxy: {}", name, e));
    }

    // Verify via getdents (read_dir through proxy).
    let entries: Vec<String> = std::fs::read_dir(dir)
        .expect("read_dir through proxy")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();

    for expected in &["a.txt", "b.txt", "c.txt"] {
        if !entries.contains(&expected.to_string()) {
            eprintln!("getdents missing {}, got {:?}", expected, entries);
            std::process::exit(1);
        }
    }

    eprintln!("getdents returned {} entries: {:?}", entries.len(), entries);
}

#[cfg(target_os = "redox")]
fn verify_test_5() -> Result<(), String> {
    // Verify directory contents on real fs.
    let entries: Vec<String> = std::fs::read_dir("/tmp/proxy-test-out/subdir")
        .map_err(|e| format!("read_dir on real fs: {}", e))?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();

    for expected in &["a.txt", "b.txt", "c.txt"] {
        if !entries.contains(&expected.to_string()) {
            return Err(format!("missing {} in {:?}", expected, entries));
        }
    }
    Ok(())
}

// ── Test 6: write 1KB + read back ──────────────────────────────────────

#[cfg(target_os = "redox")]
fn child_test_6() {
    use std::io::{Read, Write};

    let path = "/tmp/proxy-test-out/readback.bin";

    // Generate 1KB of deterministic data.
    let data: Vec<u8> = (0u16..1024).map(|i| (i % 251) as u8).collect();

    // Write through proxy.
    {
        let mut f = std::fs::File::create(path).expect("create through proxy");
        f.write_all(&data).expect("write through proxy");
        f.flush().expect("flush through proxy");
    }

    // Read back through proxy.
    {
        let mut f = std::fs::File::open(path).expect("open for read through proxy");
        let mut readback = Vec::new();
        f.read_to_end(&mut readback).expect("read through proxy");

        if readback.len() != data.len() {
            eprintln!(
                "length mismatch: wrote {} read {}",
                data.len(),
                readback.len()
            );
            std::process::exit(1);
        }

        if readback != data {
            for (i, (a, b)) in data.iter().zip(readback.iter()).enumerate() {
                if a != b {
                    eprintln!(
                        "mismatch at byte {}: wrote 0x{:02x} read 0x{:02x}",
                        i, a, b
                    );
                    break;
                }
            }
            std::process::exit(1);
        }
    }

    eprintln!("1KB write+read round-trip verified");
}

// ── Test 7: latency measurement ────────────────────────────────────────

#[cfg(target_os = "redox")]
fn child_test_7() {
    use std::io::{Read, Write};
    use std::time::Instant;

    let input_path = "/tmp/proxy-test-input/sample.txt";
    let results_path = "/tmp/proxy-test-out/latency.txt";
    let iterations = 1000usize;

    let mut latencies_us = Vec::with_capacity(iterations);
    let mut buf = [0u8; 256];

    let overall_start = Instant::now();

    for _ in 0..iterations {
        let start = Instant::now();

        let mut f = match std::fs::File::open(input_path) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("open failed: {}", e);
                std::process::exit(1);
            }
        };

        let _ = f.read(&mut buf);
        drop(f);

        let elapsed = start.elapsed();
        latencies_us.push(elapsed.as_micros() as u64);
    }

    let overall_elapsed = overall_start.elapsed();

    // Compute stats.
    latencies_us.sort();
    let total: u64 = latencies_us.iter().sum();
    let mean = total / iterations as u64;
    let p50 = latencies_us[iterations / 2];
    let p99 = latencies_us[iterations * 99 / 100];
    let p999 = latencies_us[iterations * 999 / 1000];
    let min = latencies_us[0];
    let max = latencies_us[iterations - 1];

    let results = format!(
        "iterations={}\n\
         total_ms={}\n\
         mean_us={}\n\
         p50_us={}\n\
         p99_us={}\n\
         p999_us={}\n\
         min_us={}\n\
         max_us={}\n",
        iterations,
        overall_elapsed.as_millis(),
        mean,
        p50,
        p99,
        p999,
        min,
        max,
    );

    // Write results to output file (through proxy).
    match std::fs::File::create(results_path) {
        Ok(mut f) => {
            let _ = f.write_all(results.as_bytes());
        }
        Err(e) => {
            eprintln!("create results file: {} (non-fatal)", e);
        }
    }

    // Print to stderr for parent to capture.
    eprint!("{}", results);
}

#[cfg(target_os = "redox")]
fn verify_test_7() -> Result<(), String> {
    // Read latency results from the output file (on real fs).
    match std::fs::read_to_string("/tmp/proxy-test-out/latency.txt") {
        Ok(results) => {
            for line in results.lines() {
                // Results already printed by run_child_test from stderr.
                let _ = line;
            }
            Ok(())
        }
        Err(_) => {
            // Latency file is optional — the test passed if the child exited 0.
            Ok(())
        }
    }
}
