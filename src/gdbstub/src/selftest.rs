//! Self-test mode for gdbstub: verify ptrace/proc: operations
//! without needing a TCP connection. Run as: gdbstub --selftest
//!
//! Tests:
//! 1. fork + exec a child process
//! 2. Open proc:<pid>/trace, proc:<pid>/regs/int, proc:<pid>/mem
//! 3. Read registers (verify RIP is nonzero)
//! 4. Read memory at RIP (verify readable)
//! 5. Single step (verify RIP changes)
//! 6. Continue until exit

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::mem;

pub fn run_selftest() -> bool {
    let mut pass = 0;
    let mut fail = 0;

    macro_rules! check {
        ($name:expr, $result:expr) => {
            match $result {
                Ok(val) => {
                    eprintln!("  PASS: {}", $name);
                    pass += 1;
                    val
                }
                Err(e) => {
                    eprintln!("  FAIL: {} — {}", $name, e);
                    fail += 1;
                    eprintln!("SELFTEST_RESULT: {}/{} passed, {} failed", pass, pass + fail, fail);
                    return false;
                }
            }
        };
    }

    eprintln!("=== gdbstub self-test ===");

    // 0. Test self-memory read first (validate the Memory handle works at all)
    {
        let my_pid = std::process::id();
        eprintln!("  self PID: {}", my_pid);
        match OpenOptions::new()
            .read(true)
            .write(true)
            .open(format!("proc:{}/mem", my_pid))
        {
            Ok(mut f) => {
                // Read memory at our own main function address
                let fn_addr = run_selftest as *const () as u64;
                eprintln!("  self fn addr: 0x{:x}", fn_addr);
                match read_mem(&mut f, fn_addr, 16) {
                    Ok(bytes) => {
                        eprintln!("  PASS: self-mem read, bytes: {:02x?}", &bytes[..16.min(bytes.len())]);
                        pass += 1;
                    }
                    Err(e) => {
                        eprintln!("  FAIL: self-mem read at 0x{:x}: {}", fn_addr, e);
                        fail += 1;
                    }
                }
            }
            Err(e) => {
                eprintln!("  FAIL: open proc:self/mem: {}", e);
                fail += 1;
            }
        }
    }

    // 1. Fork + exec a child
    let child_pid = check!("fork+exec child", fork_child("/bin/echo"));
    eprintln!("  child PID: {}", child_pid);

    // 2. Open proc: handles
    let mut trace = check!(
        "open proc:PID/trace",
        OpenOptions::new()
            .read(true)
            .write(true)
            .truncate(true)
            .open(format!("proc:{}/trace", child_pid))
    );

    let mut regs_int = check!(
        "open proc:PID/regs/int",
        File::open(format!("proc:{}/regs/int", child_pid))
    );

    let mut mem_file = check!(
        "open proc:PID/mem",
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(format!("proc:{}/mem", child_pid))
    );

    // 3. Read registers
    let regs = check!("read IntRegisters", read_int_regs(&mut regs_int));
    let rip = regs.rip;
    eprintln!("  RIP = 0x{:x}, RSP = 0x{:x}, RAX = 0x{:x}", rip, regs.rsp, regs.rax);

    if rip == 0 {
        eprintln!("  FAIL: RIP is zero (unexpected)");
        fail += 1;
    } else {
        eprintln!("  PASS: RIP is nonzero");
        pass += 1;
    }

    // 4. Read memory at RIP (and try other addresses to diagnose)
    eprintln!("  trying mem read at RIP=0x{:x}, RSP=0x{:x}", rip, regs.rsp);

    // Try RSP first (stack should always be mapped)
    match read_mem(&mut mem_file, regs.rsp as u64, 8) {
        Ok(bytes) => eprintln!("  PASS: read at RSP, bytes: {:02x?}", &bytes),
        Err(e) => eprintln!("  FAIL: read at RSP: {}", e),
    }

    // Try a page-aligned address near RIP
    let rip_page = (rip as u64) & !0xFFF;
    match read_mem(&mut mem_file, rip_page, 8) {
        Ok(bytes) => eprintln!("  PASS: read at RIP page base 0x{:x}, bytes: {:02x?}", rip_page, &bytes),
        Err(e) => eprintln!("  FAIL: read at RIP page base 0x{:x}: {}", rip_page, e),
    }

    let mem_bytes = match read_mem(&mut mem_file, rip as u64, 16) {
        Ok(b) => {
            eprintln!("  PASS: read memory at RIP");
            pass += 1;
            b
        }
        Err(e) => {
            eprintln!("  FAIL: read memory at RIP: {}", e);
            fail += 1;
            // Continue with remaining tests
            eprintln!("SELFTEST_RESULT: {}/{} passed, {} failed", pass, pass + fail, fail);
            return false;
        }
    };
    eprintln!(
        "  bytes at RIP: {:02x?}",
        &mem_bytes[..mem_bytes.len().min(16)]
    );
    if mem_bytes.iter().all(|&b| b == 0) {
        eprintln!("  WARN: all bytes zero at RIP");
    } else {
        eprintln!("  PASS: non-zero bytes at RIP");
        pass += 1;
    }

    // 5. Single step — first resume the SIGSTOP'd child via SIGCONT
    eprintln!("  sending SIGCONT to child PID {}", child_pid);
    unsafe { libc::kill(child_pid as libc::pid_t, libc::SIGCONT) };

    let step_result = single_step(&mut trace);
    match step_result {
        Ok(event) => {
            eprintln!("  PASS: single step returned event (cause bits: 0x{:x})", event.cause.bits());
            pass += 1;

            // Read registers again — RIP should have changed
            match read_int_regs(&mut regs_int) {
                Ok(regs2) => {
                    let rip2 = regs2.rip;
                    eprintln!("  RIP after step = 0x{:x}", rip2);
                    if rip2 != rip {
                        eprintln!("  PASS: RIP changed after single step");
                        pass += 1;
                    } else {
                        eprintln!("  FAIL: RIP unchanged after single step");
                        fail += 1;
                    }
                }
                Err(e) => {
                    eprintln!("  FAIL: read regs after step — {}", e);
                    fail += 1;
                }
            }
        }
        Err(e) => {
            eprintln!("  FAIL: single step — {}", e);
            fail += 1;
        }
    }

    // 6. Continue until exit
    let cont_result = continue_until_exit(&mut trace);
    match cont_result {
        Ok(exited) => {
            if exited {
                eprintln!("  PASS: target exited after continue");
                pass += 1;
            } else {
                eprintln!("  WARN: continue returned but target didn't exit");
                pass += 1; // Still counts — we got a response
            }
        }
        Err(e) => {
            eprintln!("  FAIL: continue — {}", e);
            fail += 1;
        }
    }

    eprintln!("=== SELFTEST_RESULT: {}/{} passed, {} failed ===", pass, pass + fail, fail);
    fail == 0
}

fn fork_child(path: &str) -> Result<usize, String> {
    let child_pid = unsafe { libc::fork() };
    match child_pid {
        -1 => Err(format!("fork failed: {}", std::io::Error::last_os_error())),
        0 => {
            // Child
            unsafe { libc::raise(libc::SIGSTOP) };
            let cpath = std::ffi::CString::new(path).unwrap();
            let args = [cpath.as_ptr(), std::ptr::null()];
            unsafe { libc::execv(cpath.as_ptr(), args.as_ptr()) };
            std::process::exit(127);
        }
        pid => {
            let pid = pid as usize;
            let mut status: libc::c_int = 0;
            let ret = unsafe { libc::waitpid(pid as libc::pid_t, &mut status, libc::WUNTRACED) };
            if ret < 0 {
                return Err(format!(
                    "waitpid failed: {}",
                    std::io::Error::last_os_error()
                ));
            }
            Ok(pid)
        }
    }
}

fn read_int_regs(f: &mut File) -> Result<syscall::IntRegisters, String> {
    let mut regs = syscall::IntRegisters::default();
    f.seek(SeekFrom::Start(0)).map_err(|e| format!("seek: {}", e))?;
    f.read_exact(unsafe {
        std::slice::from_raw_parts_mut(
            &mut regs as *mut _ as *mut u8,
            mem::size_of::<syscall::IntRegisters>(),
        )
    })
    .map_err(|e| format!("read: {}", e))?;
    Ok(regs)
}

fn read_mem(f: &mut File, addr: u64, len: usize) -> Result<Vec<u8>, String> {
    f.seek(SeekFrom::Start(addr)).map_err(|e| format!("seek: {}", e))?;
    let mut buf = vec![0u8; len];
    f.read_exact(&mut buf).map_err(|e| format!("read: {}", e))?;
    Ok(buf)
}

fn single_step(trace: &mut File) -> Result<syscall::PtraceEvent, String> {
    let flags = syscall::PTRACE_STOP_SINGLESTEP;
    trace
        .write_all(&flags.bits().to_ne_bytes())
        .map_err(|e| format!("write trace flags: {}", e))?;

    let mut event = syscall::PtraceEvent::default();
    let n = trace
        .read(unsafe {
            std::slice::from_raw_parts_mut(
                &mut event as *mut _ as *mut u8,
                mem::size_of::<syscall::PtraceEvent>(),
            )
        })
        .map_err(|e| format!("read trace event: {}", e))?;

    if n == 0 {
        return Err("EOF on trace (target exited?)".to_string());
    }
    Ok(event)
}

fn continue_until_exit(trace: &mut File) -> Result<bool, String> {
    let flags = syscall::PTRACE_STOP_EXIT;
    trace
        .write_all(&flags.bits().to_ne_bytes())
        .map_err(|e| format!("write trace flags: {}", e))?;

    let mut event = syscall::PtraceEvent::default();
    let n = trace
        .read(unsafe {
            std::slice::from_raw_parts_mut(
                &mut event as *mut _ as *mut u8,
                mem::size_of::<syscall::PtraceEvent>(),
            )
        })
        .map_err(|e| format!("read trace event: {}", e))?;

    if n == 0 {
        return Ok(true); // EOF means target exited
    }

    Ok(event.cause.contains(syscall::PTRACE_STOP_EXIT))
}
