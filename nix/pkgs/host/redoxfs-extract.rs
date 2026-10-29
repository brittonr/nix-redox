use redoxfs::{Disk, FileSystem, Node, TreePtr, BLOCK_SIZE};
use std::{env, fs::File, io::Write, os::unix::fs::FileExt};
use syscall::error::{Error, Result, EINVAL, EIO, EROFS};

// A read-only partition view: extraction must never change the guest filesystem.
struct Partition {
    file: File,
    offset: u64,
    size: u64,
}

impl Disk for Partition {
    unsafe fn read_at(&mut self, block: u64, buffer: &mut [u8]) -> Result<usize> {
        let start = block.checked_mul(BLOCK_SIZE).ok_or(Error::new(EINVAL))?;
        if start.checked_add(buffer.len() as u64).is_none_or(|end| end > self.size) {
            return Err(Error::new(EINVAL));
        }
        self.file.read_at(buffer, self.offset + start).map_err(|_| Error::new(EIO))
    }

    unsafe fn write_at(&mut self, _: u64, _: &[u8]) -> Result<usize> {
        Err(Error::new(EROFS))
    }

    fn size(&mut self) -> Result<u64> {
        Ok(self.size)
    }
}

fn extract() -> std::result::Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args().skip(1);
    let usage = "usage: redoxfs-extract DISK OFFSET_BYTES SIZE_BYTES /ABSOLUTE/PATH OUTPUT";
    let disk = args.next().ok_or(usage)?;
    let offset: u64 = args.next().ok_or(usage)?.parse()?;
    let size: u64 = args.next().ok_or(usage)?.parse()?;
    let path = args.next().ok_or(usage)?;
    let destination = args.next().ok_or(usage)?;
    if args.next().is_some() {
        return Err(usage.into());
    }
    let file = File::open(disk)?;
    let disk_size = file.metadata()?.len();
    if offset.checked_add(size).is_none_or(|end| end > disk_size) {
        return Err("partition extends beyond disk".into());
    }
    if !path.starts_with('/') || path.split('/').skip(1).any(|p| p.is_empty() || p == "." || p == "..") {
        return Err("path must be absolute with no empty or relative components".into());
    }
    let mut fs = FileSystem::open(Partition { file, offset, size }, None, None, false)?;
    let mut output = File::create(destination)?;
    fs.tx(|tx| {
        let mut ptr = TreePtr::<Node>::root();
        for component in path.split('/').skip(1) {
            ptr = tx.find_node(ptr, component)?.ptr();
        }
        let node = tx.read_tree(ptr)?;
        if !node.data().is_file() {
            return Err(Error::new(EINVAL));
        }
        let mut offset = 0;
        let mut buffer = [0u8; 65536];
        while offset < node.data().size() {
            let count = tx.read_node_inner(&node, offset, &mut buffer)?;
            if count == 0 {
                return Err(Error::new(EIO));
            }
            output.write_all(&buffer[..count]).map_err(|_| Error::new(EIO))?;
            offset += count as u64;
        }
        Ok(())
    })?;
    output.sync_all()?;
    Ok(())
}

fn main() {
    if let Err(error) = extract() {
        eprintln!("redoxfs-extract: {error}");
        std::process::exit(1);
    }
}
