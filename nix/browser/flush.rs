//! Flush regular files through the mounted guest filesystem's real fsync path.
//!
//! RedoxFS rejects fsync on directory descriptors. Recursing over real files
//! also flushes mmap-backed file contents before its filesystem transaction is
//! committed. Never follow symlinks into another scheme or pretend errors passed.
use std::{env, fs, io, path::Path};

fn flush(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_dir() {
        for entry in fs::read_dir(path)? {
            flush(&entry?.path())?;
        }
    } else if metadata.is_file() {
        fs::File::open(path)?.sync_all()?;
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let mut paths = env::args_os().skip(1).peekable();
    if paths.peek().is_none() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput,
                                  "usage: browser-demo-flush PATH..."));
    }
    for path in paths {
        flush(Path::new(&path)).map_err(|error| {
            io::Error::new(error.kind(), format!("{}: {error}", Path::new(&path).display()))
        })?;
    }
    Ok(())
}
