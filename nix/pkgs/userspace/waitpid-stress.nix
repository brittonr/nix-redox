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
