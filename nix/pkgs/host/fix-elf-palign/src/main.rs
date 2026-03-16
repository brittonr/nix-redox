//! Patch ELF program headers with p_align=0 to p_align=1.
//!
//! relibc's dynamic linker does `p_vaddr % p_align` without checking for zero,
//! causing a division-by-zero panic on segments like PT_GNU_STACK.
//!
//! This tool walks a directory tree, finds ELF files (.so, .so.6, rustc,
//! rustdoc), skips symlinks, and patches any 64-bit little-endian program
//! header with p_align=0 to p_align=1 in-place.
//!
//! Usage: fix-elf-palign <root-dir>

use std::env;
use std::fs;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

const ELF_MAGIC: [u8; 4] = [0x7f, b'E', b'L', b'F'];
const ELFCLASS64: u8 = 2;

// ELF64 header offsets
const E_PHOFF_OFFSET: u64 = 32;
const E_PHENTSIZE_OFFSET: u64 = 54;
const E_PHNUM_OFFSET: u64 = 56;

// Program header: p_align is at offset 48 in Elf64_Phdr (8 bytes, LE)
const P_ALIGN_OFFSET: u64 = 48;

fn should_process(name: &str) -> bool {
    name.ends_with(".so")
        || name.ends_with(".so.6")
        || name == "rustc"
        || name == "rustdoc"
}

fn fix_elf_palign(path: &Path) -> io::Result<bool> {
    let mut f = fs::OpenOptions::new().read(true).write(true).open(path)?;

    // Check ELF magic
    let mut magic = [0u8; 4];
    f.read_exact(&mut magic)?;
    if magic != ELF_MAGIC {
        return Ok(false);
    }

    // Check 64-bit
    let mut ei_class = [0u8; 1];
    f.read_exact(&mut ei_class)?;
    if ei_class[0] != ELFCLASS64 {
        return Ok(false);
    }

    // Read e_phoff (u64 LE at offset 32)
    f.seek(SeekFrom::Start(E_PHOFF_OFFSET))?;
    let mut buf8 = [0u8; 8];
    f.read_exact(&mut buf8)?;
    let e_phoff = u64::from_le_bytes(buf8);

    // Read e_phentsize (u16 LE at offset 54)
    f.seek(SeekFrom::Start(E_PHENTSIZE_OFFSET))?;
    let mut buf2 = [0u8; 2];
    f.read_exact(&mut buf2)?;
    let e_phentsize = u16::from_le_bytes(buf2) as u64;

    // Read e_phnum (u16 LE at offset 56)
    f.seek(SeekFrom::Start(E_PHNUM_OFFSET))?;
    f.read_exact(&mut buf2)?;
    let e_phnum = u16::from_le_bytes(buf2) as u64;

    let mut fixed = 0u32;
    for i in 0..e_phnum {
        let phdr_offset = e_phoff + i * e_phentsize;
        let align_offset = phdr_offset + P_ALIGN_OFFSET;

        f.seek(SeekFrom::Start(align_offset))?;
        f.read_exact(&mut buf8)?;
        let p_align = u64::from_le_bytes(buf8);

        if p_align == 0 {
            f.seek(SeekFrom::Start(align_offset))?;
            f.write_all(&1u64.to_le_bytes())?;
            fixed += 1;
        }
    }

    Ok(fixed > 0)
}

fn walk_and_fix(root: &Path) -> io::Result<u32> {
    let mut count = 0u32;

    // Search nix/store/ and lib/ subdirectories
    let search_dirs = [root.join("nix").join("store"), root.join("lib")];

    for search_dir in &search_dirs {
        if !search_dir.is_dir() {
            continue;
        }

        for entry in walkdir(search_dir)? {
            let entry = entry?;
            let path = entry.path();

            // Skip symlinks
            if path.symlink_metadata()?.file_type().is_symlink() {
                continue;
            }

            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) => n,
                None => continue,
            };

            if !should_process(name) {
                continue;
            }

            // Make writable, fix, restore permissions
            let meta = fs::metadata(&path)?;
            let orig_mode = meta.permissions().mode();
            fs::set_permissions(&path, fs::Permissions::from_mode(orig_mode | 0o200))?;

            match fix_elf_palign(&path) {
                Ok(true) => count += 1,
                Ok(false) => {}
                Err(e) => eprintln!("warning: {}: {}", path.display(), e),
            }

            fs::set_permissions(&path, fs::Permissions::from_mode(orig_mode))?;
        }
    }

    Ok(count)
}

/// Simple recursive directory walker (no external deps).
fn walkdir(dir: &Path) -> io::Result<Vec<io::Result<fs::DirEntry>>> {
    let mut results = Vec::new();
    walkdir_inner(dir, &mut results)?;
    Ok(results)
}

fn walkdir_inner(dir: &Path, results: &mut Vec<io::Result<fs::DirEntry>>) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let ft = entry.file_type()?;
        if ft.is_dir() {
            walkdir_inner(&entry.path(), results)?;
        } else {
            results.push(Ok(entry));
        }
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: fix-elf-palign <root-dir>");
        std::process::exit(1);
    }

    let root = Path::new(&args[1]);
    if !root.is_dir() {
        eprintln!("Error: {} is not a directory", root.display());
        std::process::exit(1);
    }

    match walk_and_fix(root) {
        Ok(count) => {
            if count > 0 {
                println!("  Fixed p_align=0 in {} ELF files", count);
            }
        }
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    /// Build a minimal 64-bit LE ELF with one program header where p_align=0.
    fn make_test_elf(p_align: u64) -> Vec<u8> {
        let mut buf = vec![0u8; 128];

        // ELF magic
        buf[0..4].copy_from_slice(&ELF_MAGIC);
        // EI_CLASS = ELFCLASS64
        buf[4] = ELFCLASS64;
        // EI_DATA = ELFDATA2LSB (little-endian)
        buf[5] = 1;

        // e_phoff = 64 (program headers start right after ELF header)
        buf[32..40].copy_from_slice(&64u64.to_le_bytes());
        // e_phentsize = 56 (standard Elf64_Phdr size)
        buf[54..56].copy_from_slice(&56u16.to_le_bytes());
        // e_phnum = 1
        buf[56..58].copy_from_slice(&1u16.to_le_bytes());

        // Program header at offset 64:
        // p_align at offset 48 within phdr = absolute offset 64+48 = 112
        buf[112..120].copy_from_slice(&p_align.to_le_bytes());

        buf
    }

    #[test]
    fn test_fixes_palign_zero() {
        let tmp = tempfile::tempdir().unwrap();
        let lib_dir = tmp.path().join("lib");
        fs::create_dir_all(&lib_dir).unwrap();

        let elf_path = lib_dir.join("test.so");
        let elf_data = make_test_elf(0);
        fs::write(&elf_path, &elf_data).unwrap();

        let count = walk_and_fix(tmp.path()).unwrap();
        assert_eq!(count, 1);

        // Verify p_align is now 1
        let patched = fs::read(&elf_path).unwrap();
        let p_align = u64::from_le_bytes(patched[112..120].try_into().unwrap());
        assert_eq!(p_align, 1);
    }

    #[test]
    fn test_skips_nonzero_palign() {
        let tmp = tempfile::tempdir().unwrap();
        let lib_dir = tmp.path().join("lib");
        fs::create_dir_all(&lib_dir).unwrap();

        let elf_path = lib_dir.join("ok.so");
        let elf_data = make_test_elf(4096);
        fs::write(&elf_path, &elf_data).unwrap();

        let count = walk_and_fix(tmp.path()).unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn test_skips_non_elf() {
        let tmp = tempfile::tempdir().unwrap();
        let lib_dir = tmp.path().join("lib");
        fs::create_dir_all(&lib_dir).unwrap();

        fs::write(lib_dir.join("readme.so"), b"not an elf").unwrap();

        let count = walk_and_fix(tmp.path()).unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn test_skips_symlinks() {
        let tmp = tempfile::tempdir().unwrap();
        let lib_dir = tmp.path().join("lib");
        fs::create_dir_all(&lib_dir).unwrap();

        let real_path = lib_dir.join("real.so");
        fs::write(&real_path, make_test_elf(0)).unwrap();

        let link_path = lib_dir.join("link.so");
        std::os::unix::fs::symlink(&real_path, &link_path).unwrap();

        let count = walk_and_fix(tmp.path()).unwrap();
        // Only real.so is fixed, link.so is skipped
        assert_eq!(count, 1);
    }

    #[test]
    fn test_processes_rustc_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let store_dir = tmp.path().join("nix").join("store").join("abc-rustc");
        fs::create_dir_all(&store_dir).unwrap();

        fs::write(store_dir.join("rustc"), make_test_elf(0)).unwrap();

        let count = walk_and_fix(tmp.path()).unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_no_search_dirs() {
        let tmp = tempfile::tempdir().unwrap();
        // No lib/ or nix/store/ — nothing to search
        let count = walk_and_fix(tmp.path()).unwrap();
        assert_eq!(count, 0);
    }
}
