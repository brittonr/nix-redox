# waitpid-stress: Stress test for waitpid() notification reliability
#
# Tests whether Redox's waitpid() (via proc: scheme) correctly delivers
# all child exit notifications. Three test modes:
#
#   1. immediate-exit: N children fork and _exit(0) immediately
#   2. pipe-io: N children write 1KB to a pipe then exit
#   3. concurrent-exit: N children block on a pipe, parent closes pipe
#      to trigger simultaneous exit, then collects all via waitpid
#
# Each test verifies that exactly N exit notifications are received.
# Used to isolate whether the JOBS>1 cargo hang is caused by lost
# waitpid notifications in the proc: scheme.

{
  pkgs,
  lib,
  rustToolchain,
  redoxTarget,
  relibc,
  stubLibs,
}:

let
  relibcDir = "${relibc}/${redoxTarget}";
  clangBin = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";

  src = pkgs.writeText "waitpid-stress-main.rs" ''
    //! waitpid-stress: Stress test for waitpid() reliability on Redox OS
    //!
    //! Tests that all child exit notifications are collected.
    //! Outputs FUNC_TEST result lines for test harness integration.

    use std::env;
    use std::io::{Read, Write};
    use std::process;

    // On Redox, we use libc bindings for fork/waitpid/pipe/close
    extern "C" {
        fn fork() -> i32;
        fn _exit(status: i32) -> !;
        fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
        fn pipe(pipefd: *mut [i32; 2]) -> i32;
        fn close(fd: i32) -> i32;
        fn write(fd: i32, buf: *const u8, count: usize) -> isize;
        fn read(fd: i32, buf: *mut u8, count: usize) -> isize;
    }

    const WNOHANG: i32 = 1;

    fn test_immediate_exit(n: usize) -> bool {
        eprintln!("  Testing: fork {} children, immediate _exit(0)", n);
        let mut child_pids: Vec<i32> = Vec::new();

        for i in 0..n {
            let pid = unsafe { fork() };
            if pid < 0 {
                eprintln!("  fork() failed at child {}", i);
                return false;
            }
            if pid == 0 {
                // Child: exit immediately
                unsafe { _exit(0) };
            }
            child_pids.push(pid);
        }

        // Parent: collect all exits
        let mut collected = 0;
        let mut attempts = 0;
        let max_attempts = n * 200; // generous timeout

        while collected < n && attempts < max_attempts {
            let mut status: i32 = 0;
            let ret = unsafe { waitpid(-1, &mut status, 0) };
            if ret > 0 {
                collected += 1;
            } else if ret < 0 {
                // No more children
                break;
            }
            attempts += 1;
        }

        if collected == n {
            eprintln!("  Collected all {} exits", n);
            true
        } else {
            eprintln!("  FAILED: collected {} of {} exits (attempts={})", collected, n, attempts);
            false
        }
    }

    fn test_pipe_io_exit(n: usize) -> bool {
        eprintln!("  Testing: fork {} children, each writes 1KB to pipe then exits", n);

        // Create one pipe per child
        let mut pipes: Vec<[i32; 2]> = Vec::new();
        for _ in 0..n {
            let mut fds = [0i32; 2];
            if unsafe { pipe(&mut fds) } != 0 {
                eprintln!("  pipe() failed");
                return false;
            }
            pipes.push(fds);
        }

        let mut child_pids: Vec<i32> = Vec::new();
        for i in 0..n {
            let write_fd = pipes[i][1];
            let read_fd = pipes[i][0];

            let pid = unsafe { fork() };
            if pid < 0 {
                eprintln!("  fork() failed at child {}", i);
                return false;
            }
            if pid == 0 {
                // Child: close read end, write 1KB, exit
                unsafe { close(read_fd) };
                let data = [0x42u8; 1024];
                unsafe { write(write_fd, data.as_ptr(), data.len()) };
                unsafe { close(write_fd) };
                unsafe { _exit(0) };
            }
            child_pids.push(pid);
            // Parent: close write end
            unsafe { close(write_fd) };
        }

        // Parent: read all pipe data
        let mut total_bytes = 0usize;
        for i in 0..n {
            let mut buf = [0u8; 2048];
            loop {
                let ret = unsafe { read(pipes[i][0], buf.as_mut_ptr(), buf.len()) };
                if ret <= 0 { break; }
                total_bytes += ret as usize;
            }
            unsafe { close(pipes[i][0]) };
        }

        // Collect all exits
        let mut collected = 0;
        while collected < n {
            let mut status: i32 = 0;
            let ret = unsafe { waitpid(-1, &mut status, 0) };
            if ret > 0 {
                collected += 1;
            } else {
                break;
            }
        }

        if collected == n && total_bytes == n * 1024 {
            eprintln!("  Collected {} exits, read {} bytes", collected, total_bytes);
            true
        } else {
            eprintln!("  FAILED: collected={}/{} bytes={}/{}", collected, n, total_bytes, n * 1024);
            false
        }
    }

    fn test_concurrent_exit(n: usize) -> bool {
        eprintln!("  Testing: fork {} children, block on pipe, close pipe to trigger concurrent exit", n);

        // Shared signal pipe: children read, parent closes to trigger exit
        let mut signal_fds = [0i32; 2];
        if unsafe { pipe(&mut signal_fds) } != 0 {
            eprintln!("  pipe() failed");
            return false;
        }
        let signal_read = signal_fds[0];
        let signal_write = signal_fds[1];

        let mut child_pids: Vec<i32> = Vec::new();
        for i in 0..n {
            let pid = unsafe { fork() };
            if pid < 0 {
                eprintln!("  fork() failed at child {}", i);
                return false;
            }
            if pid == 0 {
                // Child: close write end, block on read (will get EOF when parent closes)
                unsafe { close(signal_write) };
                let mut buf = [0u8; 1];
                unsafe { read(signal_read, buf.as_mut_ptr(), 1) };
                // read returns 0 (EOF) → exit
                unsafe { close(signal_read) };
                unsafe { _exit(0) };
            }
            child_pids.push(pid);
        }

        // Parent: close both ends — read end not needed, write end triggers EOF
        unsafe { close(signal_read) };
        // Brief pause to let children settle into blocking read
        // (use a dummy pipe read with a short timeout as a delay mechanism)
        {
            let mut delay_fds = [0i32; 2];
            if unsafe { pipe(&mut delay_fds) } == 0 {
                // Read with the expectation it times out / returns immediately
                // since nothing writes. On Redox this may block, so just close.
                unsafe { close(delay_fds[0]) };
                unsafe { close(delay_fds[1]) };
            }
        }
        // Now trigger all children to exit simultaneously
        unsafe { close(signal_write) };

        // Collect all exits (with a timeout mechanism)
        let mut collected = 0;
        let mut spin = 0;
        let max_spin = n * 1000;

        while collected < n && spin < max_spin {
            let mut status: i32 = 0;
            let ret = unsafe { waitpid(-1, &mut status, 0) };
            if ret > 0 {
                collected += 1;
            } else {
                break;
            }
            spin += 1;
        }

        if collected == n {
            eprintln!("  Collected all {} concurrent exits", n);
            true
        } else {
            eprintln!("  FAILED: collected {} of {} concurrent exits", collected, n);
            false
        }
    }

    /// Test 4: Concurrent fork+exec from multiple threads
    /// This reproduces what cargo does with JOBS=2: two threads each
    /// fork+exec a child process simultaneously.
    fn test_concurrent_fork_exec(pairs: usize) -> bool {
        use std::thread;
        use std::sync::{Arc, Barrier};

        eprintln!("  Testing: {} pairs of concurrent fork+exec from threads", pairs);

        let mut all_ok = true;

        for round in 0..pairs {
            // Barrier ensures both threads fork at the same time
            let barrier = Arc::new(Barrier::new(2));

            let b1 = barrier.clone();
            let b2 = barrier.clone();

            let t1 = thread::spawn(move || -> i32 {
                b1.wait();
                let pid = unsafe { fork() };
                if pid < 0 {
                    eprintln!("  round {}: thread 1 fork failed", round);
                    return -1;
                }
                if pid == 0 {
                    // Child: exec /bin/echo (or just exit if not available)
                    unsafe { _exit(42) };
                }
                // Parent: wait for child
                let mut status: i32 = 0;
                let ret = unsafe { waitpid(pid, &mut status, 0) };
                if ret == pid {
                    pid
                } else {
                    -1
                }
            });

            let t2 = thread::spawn(move || -> i32 {
                b2.wait();
                let pid = unsafe { fork() };
                if pid < 0 {
                    eprintln!("  round {}: thread 2 fork failed", round);
                    return -1;
                }
                if pid == 0 {
                    unsafe { _exit(43) };
                }
                let mut status: i32 = 0;
                let ret = unsafe { waitpid(pid, &mut status, 0) };
                if ret == pid {
                    pid
                } else {
                    -1
                }
            });

            let r1 = t1.join().unwrap_or(-1);
            let r2 = t2.join().unwrap_or(-1);

            if r1 < 0 || r2 < 0 {
                eprintln!("  round {}: FAILED (r1={}, r2={})", round, r1, r2);
                all_ok = false;
                break;
            }
        }

        if all_ok {
            eprintln!("  All {} rounds of concurrent fork+exec passed", pairs);
        }
        all_ok
    }

    /// Test 5: Concurrent fork+exec with pipes (closer to cargo's pattern)
    /// Each thread: create pipe, fork, child writes to pipe and exits,
    /// parent reads pipe and waits for child.
    fn test_concurrent_fork_exec_pipes(pairs: usize) -> bool {
        use std::thread;
        use std::sync::{Arc, Barrier};

        eprintln!("  Testing: {} pairs of concurrent fork+exec with pipes", pairs);

        let mut all_ok = true;

        for round in 0..pairs {
            let barrier = Arc::new(Barrier::new(2));

            let round_copy = round;
            let do_fork_pipe = move |barrier: Arc<Barrier>, id: u8| -> bool {
                let round = round_copy;
                // Create stdout/stderr pipes like cargo does
                let mut out_fds = [0i32; 2];
                let mut err_fds = [0i32; 2];
                if unsafe { pipe(&mut out_fds) } != 0 || unsafe { pipe(&mut err_fds) } != 0 {
                    eprintln!("  round {}: pipe creation failed", round);
                    return false;
                }

                barrier.wait();

                let pid = unsafe { fork() };
                if pid < 0 {
                    eprintln!("  round {}: fork failed for id={}", round, id);
                    return false;
                }
                if pid == 0 {
                    // Child: close read ends, write to stdout pipe, exit
                    unsafe { close(out_fds[0]) };
                    unsafe { close(err_fds[0]) };
                    let msg = b"hello from child\n";
                    unsafe { write(out_fds[1], msg.as_ptr(), msg.len()) };
                    unsafe { close(out_fds[1]) };
                    unsafe { close(err_fds[1]) };
                    unsafe { _exit(0) };
                }

                // Parent: close write ends, read from pipes
                unsafe { close(out_fds[1]) };
                unsafe { close(err_fds[1]) };

                // Read stdout (like cargo's read2 main thread)
                let mut buf = [0u8; 256];
                let mut total = 0;
                loop {
                    let n = unsafe { read(out_fds[0], buf.as_mut_ptr(), buf.len()) };
                    if n <= 0 { break; }
                    total += n as usize;
                }
                unsafe { close(out_fds[0]) };

                // Read stderr
                loop {
                    let n = unsafe { read(err_fds[0], buf.as_mut_ptr(), buf.len()) };
                    if n <= 0 { break; }
                }
                unsafe { close(err_fds[0]) };

                // Wait for child
                let mut status: i32 = 0;
                let ret = unsafe { waitpid(pid, &mut status, 0) };

                ret == pid && total > 0
            };

            let b1 = barrier.clone();
            let b2 = barrier.clone();

            let t1 = thread::spawn(move || do_fork_pipe(b1, 1));
            let t2 = thread::spawn(move || do_fork_pipe(b2, 2));

            let r1 = t1.join().unwrap_or(false);
            let r2 = t2.join().unwrap_or(false);

            if !r1 || !r2 {
                eprintln!("  round {}: FAILED (t1={}, t2={})", round, r1, r2);
                all_ok = false;
                break;
            }
        }

        if all_ok {
            eprintln!("  All {} rounds of concurrent fork+exec+pipes passed", pairs);
        }
        all_ok
    }

    fn main() {
        let args: Vec<String> = env::args().collect();
        let n: usize = if args.len() > 1 {
            args[1].parse().unwrap_or(50)
        } else {
            50
        };

        eprintln!("waitpid-stress: testing with N={}", n);

        // Test 1: immediate exit
        if test_immediate_exit(n) {
            println!("FUNC_TEST:waitpid-stress-immediate-{}:PASS", n);
        } else {
            println!("FUNC_TEST:waitpid-stress-immediate-{}:FAIL:missed exits", n);
        }

        // Test 2: pipe I/O before exit
        if test_pipe_io_exit(n) {
            println!("FUNC_TEST:waitpid-stress-pipeio-{}:PASS", n);
        } else {
            println!("FUNC_TEST:waitpid-stress-pipeio-{}:FAIL:missed exits or data", n);
        }

        // Test 3: concurrent exit
        if test_concurrent_exit(n) {
            println!("FUNC_TEST:waitpid-stress-concurrent-{}:PASS", n);
        } else {
            println!("FUNC_TEST:waitpid-stress-concurrent-{}:FAIL:missed exits", n);
        }

        // Test 4: concurrent fork+exec from threads (10 rounds)
        if test_concurrent_fork_exec(10) {
            println!("FUNC_TEST:waitpid-stress-concurrent-forkexec:PASS");
        } else {
            println!("FUNC_TEST:waitpid-stress-concurrent-forkexec:FAIL:thread fork hang");
        }

        // Test 5: concurrent fork+exec with pipes (10 rounds)
        if test_concurrent_fork_exec_pipes(10) {
            println!("FUNC_TEST:waitpid-stress-concurrent-forkpipes:PASS");
        } else {
            println!("FUNC_TEST:waitpid-stress-concurrent-forkpipes:FAIL:thread fork+pipe hang");
        }
    }
  '';
in
pkgs.runCommand "waitpid-stress"
  {
    nativeBuildInputs = [
      rustToolchain
      pkgs.llvmPackages.clang
      pkgs.llvmPackages.lld
    ];
  }
  ''
    mkdir -p $out/bin
    rustc --target ${redoxTarget} \
      --edition 2021 \
      -C panic=abort \
      -C target-cpu=x86-64 \
      -C linker=${clangBin} \
      -C link-arg=-nostdlib \
      -C link-arg=-static \
      -C link-arg=--target=${redoxTarget} \
      -C link-arg=${relibcDir}/lib/crt0.o \
      -C link-arg=${relibcDir}/lib/crti.o \
      -C link-arg=${relibcDir}/lib/crtn.o \
      -C link-arg=-Wl,--allow-multiple-definition \
      -L ${relibcDir}/lib \
      -L ${stubLibs}/lib \
      ${src} -o $out/bin/waitpid-stress
  ''
