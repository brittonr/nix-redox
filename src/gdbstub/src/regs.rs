//! x86_64 register mapping between Redox IntRegisters and GDB register file.
//!
//! GDB's x86_64 register file layout (from gdb/features/i386/64bit-core.xml):
//!   rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp,
//!   r8, r9, r10, r11, r12, r13, r14, r15,
//!   rip, eflags, cs, ss, ds, es, fs, gs
//!
//! Each general-purpose register is 8 bytes (64 bits), little-endian hex.
//! Segment registers are 4 bytes each.
//!
//! Redox IntRegisters layout (redox_syscall 0.5, x86_64):
//!   r15, r14, r13, r12, rbp, rbx, r11, r10, r9, r8,
//!   rax, rcx, rdx, rsi, rdi, rip, cs, rflags, rsp, ss

/// Serialize Redox IntRegisters to GDB hex format.
pub fn int_regs_to_gdb_hex(regs: &syscall::IntRegisters) -> String {
    let mut hex = String::with_capacity(400);

    // General purpose registers (8 bytes each, LE)
    hex.push_str(&reg64_hex(regs.rax));
    hex.push_str(&reg64_hex(regs.rbx));
    hex.push_str(&reg64_hex(regs.rcx));
    hex.push_str(&reg64_hex(regs.rdx));
    hex.push_str(&reg64_hex(regs.rsi));
    hex.push_str(&reg64_hex(regs.rdi));
    hex.push_str(&reg64_hex(regs.rbp));
    hex.push_str(&reg64_hex(regs.rsp));
    hex.push_str(&reg64_hex(regs.r8));
    hex.push_str(&reg64_hex(regs.r9));
    hex.push_str(&reg64_hex(regs.r10));
    hex.push_str(&reg64_hex(regs.r11));
    hex.push_str(&reg64_hex(regs.r12));
    hex.push_str(&reg64_hex(regs.r13));
    hex.push_str(&reg64_hex(regs.r14));
    hex.push_str(&reg64_hex(regs.r15));

    // rip (8 bytes)
    hex.push_str(&reg64_hex(regs.rip));

    // eflags (4 bytes)
    hex.push_str(&reg32_hex(regs.rflags as u32));

    // Segment registers (4 bytes each)
    hex.push_str(&reg32_hex(regs.cs as u32));
    hex.push_str(&reg32_hex(regs.ss as u32));
    hex.push_str(&reg32_hex(0)); // ds
    hex.push_str(&reg32_hex(0)); // es
    hex.push_str(&reg32_hex(0)); // fs
    hex.push_str(&reg32_hex(0)); // gs

    hex
}

/// Deserialize GDB hex register data into Redox IntRegisters.
pub fn gdb_hex_to_int_regs(hex: &[u8], regs: &mut syscall::IntRegisters) -> bool {
    let mut pos = 0;

    macro_rules! read_le64 {
        () => {{
            if pos + 16 > hex.len() {
                return false;
            }
            let bytes = match hex_decode_slice(&hex[pos..pos + 16]) {
                Some(b) => b,
                None => return false,
            };
            pos += 16;
            usize::from_le_bytes(bytes.try_into().unwrap_or([0; 8]))
        }};
    }

    macro_rules! read_le32 {
        () => {{
            if pos + 8 > hex.len() {
                return false;
            }
            let bytes = match hex_decode_slice(&hex[pos..pos + 8]) {
                Some(b) => b,
                None => return false,
            };
            pos += 8;
            u32::from_le_bytes(bytes.try_into().unwrap_or([0; 4])) as usize
        }};
    }

    regs.rax = read_le64!();
    regs.rbx = read_le64!();
    regs.rcx = read_le64!();
    regs.rdx = read_le64!();
    regs.rsi = read_le64!();
    regs.rdi = read_le64!();
    regs.rbp = read_le64!();
    regs.rsp = read_le64!();
    regs.r8 = read_le64!();
    regs.r9 = read_le64!();
    regs.r10 = read_le64!();
    regs.r11 = read_le64!();
    regs.r12 = read_le64!();
    regs.r13 = read_le64!();
    regs.r14 = read_le64!();
    regs.r15 = read_le64!();
    regs.rip = read_le64!();
    regs.rflags = read_le32!();
    regs.cs = read_le32!();
    regs.ss = read_le32!();
    let _ds = read_le32!();
    let _es = read_le32!();
    let _fs = read_le32!();
    let _gs = read_le32!();

    true
}

pub fn get_rip(regs: &syscall::IntRegisters) -> u64 {
    regs.rip as u64
}

pub fn set_rip(regs: &mut syscall::IntRegisters, rip: u64) {
    regs.rip = rip as usize;
}

fn reg64_hex(val: usize) -> String {
    let bytes = (val as u64).to_le_bytes();
    let mut s = String::with_capacity(16);
    for b in &bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn reg32_hex(val: u32) -> String {
    let bytes = val.to_le_bytes();
    let mut s = String::with_capacity(8);
    for b in &bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn hex_decode_slice(hex: &[u8]) -> Option<Vec<u8>> {
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
