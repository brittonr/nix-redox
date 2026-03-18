//! GDB remote debugging stub for Redox OS
//!
//! Translates GDB Remote Serial Protocol commands into Redox proc: scheme
//! operations. Supports attach-by-PID or launch-and-debug.
//!
//! Usage:
//!   gdbstub <pid> [--port <port>]
//!   gdbstub --exec <path> [args...] [--port <port>]

use gdb_protocol::{
    io::GdbServer,
    packet::{CheckedPacket, Kind},
};
use std::collections::HashMap;
use std::env;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::mem;
use std::process;

mod regs;
use regs::{int_regs_to_gdb_hex, gdb_hex_to_int_regs};

// Default GDB listen port
const DEFAULT_PORT: u16 = 1234;

/// State for the ptrace-attached target process.
struct Target {
    pid: usize,
    regs_int: File,
    regs_float: File,
    mem: File,
    trace: File,
    /// Software breakpoints: address → original byte
    breakpoints: HashMap<u64, u8>,
    /// Whether the target has exited
    exited: bool,
}

impl Target {
    fn attach(pid: usize) -> io::Result<Self> {
        let trace = OpenOptions::new()
            .read(true)
            .write(true)
            .truncate(true)
            .open(format!("proc:{}/trace", pid))?;
        let regs_int = File::open(format!("proc:{}/regs/int", pid))?;
        let regs_float = File::open(format!("proc:{}/regs/float", pid))?;
        let mem = OpenOptions::new()
            .read(true)
            .write(true)
            .open(format!("proc:{}/mem", pid))?;

        Ok(Target {
            pid,
            regs_int,
            regs_float,
            mem,
            trace,
            breakpoints: HashMap::new(),
            exited: false,
        })
    }

    fn read_int_regs(&mut self) -> io::Result<syscall::IntRegisters> {
        let mut regs = syscall::IntRegisters::default();
        self.regs_int.seek(SeekFrom::Start(0))?;
        self.regs_int.read_exact(unsafe {
            std::slice::from_raw_parts_mut(
                &mut regs as *mut _ as *mut u8,
                mem::size_of::<syscall::IntRegisters>(),
            )
        })?;
        Ok(regs)
    }

    fn write_int_regs(&mut self, regs: &syscall::IntRegisters) -> io::Result<()> {
        self.regs_int.seek(SeekFrom::Start(0))?;
        self.regs_int.write_all(unsafe {
            std::slice::from_raw_parts(
                regs as *const _ as *const u8,
                mem::size_of::<syscall::IntRegisters>(),
            )
        })
    }

    fn read_memory(&mut self, addr: u64, len: usize) -> io::Result<Vec<u8>> {
        self.mem.seek(SeekFrom::Start(addr))?;
        let mut buf = vec![0u8; len];
        self.mem.read_exact(&mut buf)?;
        Ok(buf)
    }

    fn write_memory(&mut self, addr: u64, data: &[u8]) -> io::Result<()> {
        self.mem.seek(SeekFrom::Start(addr))?;
        self.mem.write_all(data)
    }

    fn insert_breakpoint(&mut self, addr: u64) -> io::Result<()> {
        if self.breakpoints.contains_key(&addr) {
            return Ok(()); // Already set
        }
        let mut orig = [0u8; 1];
        self.mem.seek(SeekFrom::Start(addr))?;
        self.mem.read_exact(&mut orig)?;
        self.mem.seek(SeekFrom::Start(addr))?;
        self.mem.write_all(&[0xCC])?; // int3
        self.breakpoints.insert(addr, orig[0]);
        Ok(())
    }

    fn remove_breakpoint(&mut self, addr: u64) -> io::Result<()> {
        if let Some(orig) = self.breakpoints.remove(&addr) {
            self.mem.seek(SeekFrom::Start(addr))?;
            self.mem.write_all(&[orig])?;
        }
        Ok(())
    }

    /// Continue execution, waiting for the next stop event.
    fn continue_exec(&mut self) -> io::Result<StopReason> {
        use syscall::PTRACE_STOP_BREAKPOINT;

        // Write breakpoint flags: stop on everything
        let flags = syscall::PTRACE_STOP_PRE_SYSCALL
            | syscall::PTRACE_STOP_POST_SYSCALL
            | syscall::PTRACE_STOP_SINGLESTEP
            | syscall::PTRACE_STOP_SIGNAL
            | syscall::PTRACE_STOP_BREAKPOINT
            | syscall::PTRACE_STOP_EXIT;

        self.trace.write_all(&flags.bits().to_ne_bytes())?;
        self.wait_for_event()
    }

    /// Single step one instruction.
    fn single_step(&mut self) -> io::Result<StopReason> {
        let flags = syscall::PTRACE_STOP_SINGLESTEP;
        self.trace.write_all(&flags.bits().to_ne_bytes())?;
        self.wait_for_event()
    }

    fn wait_for_event(&mut self) -> io::Result<StopReason> {
        let mut event = syscall::PtraceEvent::default();
        let n = self.trace.read(unsafe {
            std::slice::from_raw_parts_mut(
                &mut event as *mut _ as *mut u8,
                mem::size_of::<syscall::PtraceEvent>(),
            )
        })?;

        if n == 0 {
            self.exited = true;
            return Ok(StopReason::Exited(0));
        }

        let cause = event.cause;
        if cause.contains(syscall::PTRACE_STOP_BREAKPOINT) {
            // int3 increments RIP past the 0xCC — rewind by 1
            if let Ok(mut regs) = self.read_int_regs() {
                let rip = regs::get_rip(&regs);
                if rip > 0 && self.breakpoints.contains_key(&(rip - 1)) {
                    regs::set_rip(&mut regs, rip - 1);
                    let _ = self.write_int_regs(&regs);
                }
            }
            Ok(StopReason::Signal(5)) // SIGTRAP
        } else if cause.contains(syscall::PTRACE_STOP_SINGLESTEP) {
            Ok(StopReason::Signal(5)) // SIGTRAP
        } else if cause.contains(syscall::PTRACE_STOP_EXIT) {
            self.exited = true;
            Ok(StopReason::Exited(event.a as u8))
        } else if cause.contains(syscall::PTRACE_STOP_SIGNAL) {
            Ok(StopReason::Signal(event.a as u8))
        } else {
            // Pre/post syscall — treat as SIGTRAP
            Ok(StopReason::Signal(5))
        }
    }
}

enum StopReason {
    Signal(u8),
    Exited(u8),
}

impl StopReason {
    fn to_rsp(&self) -> String {
        match self {
            StopReason::Signal(sig) => format!("S{:02x}", sig),
            StopReason::Exited(code) => format!("W{:02x}", code),
        }
    }
}

fn hex_encode(data: &[u8]) -> String {
    let mut s = String::with_capacity(data.len() * 2);
    for b in data {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn hex_decode(hex: &[u8]) -> Option<Vec<u8>> {
    if hex.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(hex.len() / 2);
    for chunk in hex.chunks(2) {
        let s = std::str::from_utf8(chunk).ok()?;
        out.push(u8::from_str_radix(s, 16).ok()?);
    }
    Some(out)
}

fn parse_hex_u64(hex: &[u8]) -> Option<u64> {
    let s = std::str::from_utf8(hex).ok()?;
    u64::from_str_radix(s, 16).ok()
}

fn handle_packet(
    target: &mut Target,
    data: &[u8],
) -> String {
    if data.is_empty() {
        return String::new();
    }

    match data[0] {
        b'?' => {
            // Stop reason query
            "S05".to_string() // Stopped (SIGTRAP)
        }

        b'g' => {
            // Read registers
            match target.read_int_regs() {
                Ok(regs) => int_regs_to_gdb_hex(&regs),
                Err(_) => "E01".to_string(),
            }
        }

        b'G' => {
            // Write registers
            match target.read_int_regs() {
                Ok(mut regs) => {
                    if gdb_hex_to_int_regs(&data[1..], &mut regs) {
                        match target.write_int_regs(&regs) {
                            Ok(()) => "OK".to_string(),
                            Err(_) => "E01".to_string(),
                        }
                    } else {
                        "E01".to_string()
                    }
                }
                Err(_) => "E01".to_string(),
            }
        }

        b'm' => {
            // Read memory: m addr,length
            let params = &data[1..];
            if let Some(comma) = params.iter().position(|&b| b == b',') {
                let addr = parse_hex_u64(&params[..comma]);
                let len = parse_hex_u64(&params[comma + 1..]);
                if let (Some(addr), Some(len)) = (addr, len) {
                    match target.read_memory(addr, len as usize) {
                        Ok(bytes) => hex_encode(&bytes),
                        Err(_) => "E14".to_string(), // EFAULT
                    }
                } else {
                    "E01".to_string()
                }
            } else {
                "E01".to_string()
            }
        }

        b'M' => {
            // Write memory: M addr,length:XX...
            let params = &data[1..];
            if let Some(colon) = params.iter().position(|&b| b == b':') {
                let header = &params[..colon];
                let hex_data = &params[colon + 1..];
                if let Some(comma) = header.iter().position(|&b| b == b',') {
                    let addr = parse_hex_u64(&header[..comma]);
                    if let Some(addr) = addr {
                        if let Some(bytes) = hex_decode(hex_data) {
                            match target.write_memory(addr, &bytes) {
                                Ok(()) => "OK".to_string(),
                                Err(_) => "E14".to_string(),
                            }
                        } else {
                            "E01".to_string()
                        }
                    } else {
                        "E01".to_string()
                    }
                } else {
                    "E01".to_string()
                }
            } else {
                "E01".to_string()
            }
        }

        b'c' => {
            // Continue
            match target.continue_exec() {
                Ok(reason) => reason.to_rsp(),
                Err(_) => "E01".to_string(),
            }
        }

        b's' => {
            // Single step
            match target.single_step() {
                Ok(reason) => reason.to_rsp(),
                Err(_) => "E01".to_string(),
            }
        }

        b'Z' if data.len() > 1 && data[1] == b'0' => {
            // Insert software breakpoint: Z0,addr,kind
            let params = &data[3..]; // skip "Z0,"
            if let Some(comma) = params.iter().position(|&b| b == b',') {
                if let Some(addr) = parse_hex_u64(&params[..comma]) {
                    match target.insert_breakpoint(addr) {
                        Ok(()) => "OK".to_string(),
                        Err(_) => "E01".to_string(),
                    }
                } else {
                    "E01".to_string()
                }
            } else {
                "E01".to_string()
            }
        }

        b'z' if data.len() > 1 && data[1] == b'0' => {
            // Remove software breakpoint: z0,addr,kind
            let params = &data[3..]; // skip "z0,"
            if let Some(comma) = params.iter().position(|&b| b == b',') {
                if let Some(addr) = parse_hex_u64(&params[..comma]) {
                    match target.remove_breakpoint(addr) {
                        Ok(()) => "OK".to_string(),
                        Err(_) => "E01".to_string(),
                    }
                } else {
                    "E01".to_string()
                }
            } else {
                "E01".to_string()
            }
        }

        b'H' => {
            // Thread select: Hg<tid> or Hc<tid>
            // Redox doesn't have threads per-process — always OK
            "OK".to_string()
        }

        b'q' => {
            // Query packets
            if data.starts_with(b"qSupported") {
                "PacketSize=4096".to_string()
            } else if data.starts_with(b"qAttached") {
                "1".to_string() // Attached to existing process
            } else if data.starts_with(b"qC") {
                // Current thread ID
                format!("QC{:x}", target.pid)
            } else {
                String::new() // Unsupported query
            }
        }

        b'k' => {
            // Kill target
            unsafe { libc::kill(target.pid as i32, libc::SIGKILL) };
            target.exited = true;
            String::new()
        }

        b'D' => {
            // Detach
            "OK".to_string()
        }

        _ => {
            // Unsupported — return empty per RSP spec
            String::new()
        }
    }
}

fn run_stub(target: &mut Target, port: u16) -> io::Result<()> {
    eprintln!("gdbstub: attached to PID {}", target.pid);
    eprintln!("gdbstub: listening on 0.0.0.0:{}", port);
    eprintln!("gdbstub: connect with: target remote <ip>:{}", port);

    let mut server = GdbServer::listen(format!("0.0.0.0:{}", port))
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("{}", e)))?;

    eprintln!("gdbstub: client connected");

    loop {
        let packet = server
            .next_packet()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("{}", e)))?;

        let packet = match packet {
            Some(p) => p,
            None => {
                eprintln!("gdbstub: client disconnected");
                break;
            }
        };

        let response_str = handle_packet(target, &packet.data);

        // Handle detach and kill specially
        if packet.data.first() == Some(&b'D') || packet.data.first() == Some(&b'k') {
            if !response_str.is_empty() {
                let response = CheckedPacket::from_data(Kind::Packet, response_str.into_bytes());
                let _ = server.dispatch(&response);
            }
            break;
        }

        let response = CheckedPacket::from_data(Kind::Packet, response_str.into_bytes());
        server
            .dispatch(&response)
            .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("{}", e)))?;

        if target.exited {
            eprintln!("gdbstub: target exited");
            break;
        }
    }

    Ok(())
}

fn usage() {
    eprintln!("Usage: gdbstub <pid> [--port <port>]");
    eprintln!("       gdbstub --exec <path> [args...] [--port <port>]");
    eprintln!();
    eprintln!("Attach to a process or launch one, then listen for GDB connections.");
    eprintln!("Default port: {}", DEFAULT_PORT);
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        usage();
        process::exit(1);
    }

    let mut port = DEFAULT_PORT;
    let mut pid: Option<usize> = None;
    let mut exec_path: Option<String> = None;
    let mut exec_args: Vec<String> = Vec::new();
    let mut i = 0;
    let mut in_exec = false;

    while i < args.len() {
        match args[i].as_str() {
            "--port" => {
                i += 1;
                if i < args.len() {
                    port = args[i].parse().unwrap_or_else(|_| {
                        eprintln!("Invalid port: {}", args[i]);
                        process::exit(1);
                    });
                }
            }
            "--exec" => {
                i += 1;
                if i < args.len() {
                    exec_path = Some(args[i].clone());
                    in_exec = true;
                }
            }
            "-h" | "--help" => {
                usage();
                process::exit(0);
            }
            arg => {
                if in_exec {
                    exec_args.push(arg.to_string());
                } else if pid.is_none() {
                    pid = Some(arg.parse().unwrap_or_else(|_| {
                        eprintln!("Invalid PID: {}", arg);
                        process::exit(1);
                    }));
                } else {
                    eprintln!("Unexpected argument: {}", arg);
                    process::exit(1);
                }
            }
        }
        i += 1;
    }

    let target_pid = if let Some(path) = exec_path {
        // Launch mode: fork + SIGSTOP + exec
        match launch_process(&path, &exec_args) {
            Ok(child_pid) => child_pid,
            Err(e) => {
                eprintln!("gdbstub: failed to launch {}: {}", path, e);
                process::exit(1);
            }
        }
    } else if let Some(p) = pid {
        p
    } else {
        usage();
        process::exit(1);
    };

    let mut target = match Target::attach(target_pid) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("gdbstub: failed to attach to PID {}: {}", target_pid, e);
            process::exit(1);
        }
    };

    if let Err(e) = run_stub(&mut target, port) {
        eprintln!("gdbstub: error: {}", e);
        process::exit(1);
    }
}

fn launch_process(path: &str, args: &[String]) -> io::Result<usize> {
    let child_pid = unsafe { libc::fork() };
    match child_pid {
        -1 => Err(io::Error::last_os_error()),
        0 => {
            // Child: stop self so parent can attach, then exec
            unsafe { libc::raise(libc::SIGSTOP) };

            let mut cargs: Vec<std::ffi::CString> = Vec::new();
            cargs.push(std::ffi::CString::new(path).unwrap());
            for a in args {
                cargs.push(std::ffi::CString::new(a.as_str()).unwrap());
            }
            let ptrs: Vec<*const libc::c_char> = cargs
                .iter()
                .map(|s| s.as_ptr())
                .chain(std::iter::once(std::ptr::null()))
                .collect();

            let cpath = std::ffi::CString::new(path).unwrap();
            unsafe { libc::execv(cpath.as_ptr(), ptrs.as_ptr()) };
            Err(io::Error::last_os_error())
        }
        pid => {
            // Parent: wait for child to stop, then return its PID
            let pid = pid as usize;
            let mut status: libc::c_int = 0;
            let ret = unsafe { libc::waitpid(pid as libc::pid_t, &mut status, libc::WUNTRACED) };
            if ret < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(pid)
        }
    }
}
