//! SnixRedoxIO — EvalIO implementation for Redox OS.
//!
//! Provides filesystem I/O to the snix-eval bytecode VM with two
//! extensions over the default StdIO:
//!
//! 1. **Store-aware path imports**: `import_path` copies local files
//!    into `/nix/store/` as content-addressed paths (NAR SHA-256),
//!    matching upstream Nix behavior for path interpolation.
//!
//! 2. **Build-on-demand**: When evaluation needs a store path that
//!    doesn't exist yet (e.g. `import "${drv}"`), the IO layer looks
//!    up the derivation that produces it, builds it (and its deps),
//!    then returns the result. This enables Import From Derivation.
//!
//! 3. **`builtins.storeDir`**: Returns `"/nix/store"`.

use std::cell::RefCell;
use std::ffi::{OsStr, OsString};
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use nix_compat::nixhash::{CAHash, NixHash};
use nix_compat::store_path::{build_ca_path, StorePath, STORE_DIR, STORE_DIR_WITH_SLASH};
use sha2::{Digest, Sha256};
use snix_eval::{EvalIO, FileType};

use crate::derivation_builtins::SnixRedoxState;
use crate::local_build;
use crate::pathinfo::{self, PathInfoDb};

#[cfg(unix)]
use std::os::unix::ffi::OsStringExt;

// ── SnixRedoxIO ────────────────────────────────────────────────────────────

/// EvalIO implementation with store-aware imports and build-on-demand.
pub struct SnixRedoxIO {
    /// Shared state with derivation builtins (KnownPaths)
    state: Rc<SnixRedoxState>,
    /// Path info database for registration and lookup
    db: RefCell<Option<PathInfoDb>>,
}

impl SnixRedoxIO {
    /// Create a new SnixRedoxIO sharing state with derivation builtins.
    pub fn new(state: Rc<SnixRedoxState>) -> Self {
        Self {
            state,
            db: RefCell::new(None),
        }
    }

    /// Lazily open the PathInfoDb (avoids errors when /nix/var doesn't exist).
    fn db(&self) -> io::Result<std::cell::Ref<'_, PathInfoDb>> {
        {
            let mut db = self.db.borrow_mut();
            if db.is_none() {
                *db = Some(
                    PathInfoDb::open()
                        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?,
                );
            }
        }
        Ok(std::cell::Ref::map(self.db.borrow(), |opt| {
            opt.as_ref().unwrap()
        }))
    }

    /// If `path` is under `/nix/store/` and doesn't exist, try to build
    /// the derivation that produces it.
    ///
    /// Returns `true` if the path now exists (either it already did, or
    /// we successfully built it).
    fn ensure_store_path(&self, path: &Path) -> bool {
        // Fast path: already exists
        if path.exists() {
            return true;
        }

        let path_str = path.to_string_lossy();
        if !path_str.starts_with(STORE_DIR_WITH_SLASH) {
            return false;
        }

        // Extract the store path (first component after /nix/store/)
        let store_path = match self.extract_store_path(path) {
            Some(sp) => sp,
            None => return false,
        };

        // Look up which derivation produces this output
        let known_paths = self.state.known_paths.borrow();
        let drv_path = match known_paths.get_drv_path_for_output_path(&store_path) {
            Some(dp) => dp.clone(),
            None => return false,
        };

        // Build it (and its dependencies)
        let db = match self.db() {
            Ok(db) => db,
            Err(_) => return false,
        };

        eprintln!(
            "snix-io: building {} for {}",
            drv_path,
            store_path.to_absolute_path()
        );

        match local_build::build_needed(&drv_path, &*known_paths, &db) {
            Ok(_) => path.exists(),
            Err(e) => {
                eprintln!("snix-io: build failed: {e}");
                false
            }
        }
    }

    /// Extract the StorePath from an absolute path (which may have
    /// sub-path components like `/nix/store/abc...-foo/bin/hello`).
    fn extract_store_path(&self, path: &Path) -> Option<StorePath<String>> {
        let path_str = path.to_string_lossy();
        // The store path is the first 44 chars after /nix/store/
        // (32 hash + 1 dash + variable name, terminated by / or end)
        if path_str.len() < STORE_DIR_WITH_SLASH.len() + 32 {
            return None;
        }

        // Find the end of the store path name
        let after_store = &path_str[STORE_DIR_WITH_SLASH.len()..];
        let name_end = after_store.find('/').unwrap_or(after_store.len());
        let store_basename = &after_store[..name_end];
        let full_path = format!("{STORE_DIR_WITH_SLASH}{store_basename}");

        StorePath::<String>::from_absolute_path(full_path.as_bytes()).ok()
    }

    /// Import a local path into the Nix store as a content-addressed path.
    ///
    /// 1. Serialize path to NAR format
    /// 2. SHA-256 hash the NAR
    /// 3. Compute content-addressed store path
    /// 4. Copy files to store (if not already there)
    /// 5. Register in PathInfoDb
    /// 6. Return the store path
    fn import_to_store(&self, path: &Path) -> io::Result<PathBuf> {
        // Get the canonical path and its basename
        let canon = fs::canonicalize(path)?;
        let name = canon
            .file_name()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no filename"))?
            .to_string_lossy();

        // Sanitize the name for Nix store (replace invalid chars)
        let name = sanitize_store_name(&name);

        // Compute NAR hash
        let (nar_hash_hex, nar_size) = local_build::nar_hash_path(&canon)?;

        // Extract the raw SHA-256 bytes from "sha256:<hex>"
        let hex_str = nar_hash_hex
            .strip_prefix("sha256:")
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "unexpected hash format"))?;
        let mut hash_bytes = [0u8; 32];
        for (i, chunk) in hex_str.as_bytes().chunks(2).enumerate() {
            if i >= 32 {
                break;
            }
            hash_bytes[i] = u8::from_str_radix(
                std::str::from_utf8(chunk).unwrap_or("00"),
                16,
            )
            .unwrap_or(0);
        }

        // Compute content-addressed store path
        let ca_hash = CAHash::Nar(NixHash::Sha256(hash_bytes));
        let store_path: StorePath<String> = build_ca_path(
            &name,
            &ca_hash,
            Vec::<&str>::new(),
            false,
        )
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;

        let dest = PathBuf::from(store_path.to_absolute_path());

        // Copy to store if not already there
        if !dest.exists() {
            fs::create_dir_all(STORE_DIR)?;
            copy_path(&canon, &dest)?;

            // Register in PathInfoDb
            if let Ok(db) = self.db() {
                let info = pathinfo::PathInfo {
                    store_path: store_path.to_absolute_path(),
                    nar_hash: nar_hash_hex,
                    nar_size,
                    references: vec![],
                    deriver: None,
                    registration_time: pathinfo::current_timestamp(),
                    signatures: vec![],
                    files: vec![],
                };
                let _ = db.register(&info);
            }
        }

        Ok(dest)
    }
}

impl EvalIO for SnixRedoxIO {
    fn path_exists(&self, path: &Path) -> io::Result<bool> {
        if path.try_exists().unwrap_or(false) {
            return Ok(true);
        }

        // Try build-on-demand for store paths
        Ok(self.ensure_store_path(path))
    }

    fn open(&self, path: &Path) -> io::Result<Box<dyn io::Read>> {
        self.ensure_store_path(path);
        Ok(Box::new(File::open(path)?))
    }

    fn file_type(&self, path: &Path) -> io::Result<FileType> {
        self.ensure_store_path(path);
        let meta = fs::symlink_metadata(path)?;

        Ok(if meta.is_dir() {
            FileType::Directory
        } else if meta.is_file() {
            FileType::Regular
        } else if meta.is_symlink() {
            FileType::Symlink
        } else {
            FileType::Unknown
        })
    }

    fn read_dir(&self, path: &Path) -> io::Result<Vec<(bytes::Bytes, FileType)>> {
        self.ensure_store_path(path);

        let mut result = vec![];
        for entry in path.read_dir()? {
            let entry = entry?;
            let file_type = entry.file_type()?;

            let val = if file_type.is_dir() {
                FileType::Directory
            } else if file_type.is_file() {
                FileType::Regular
            } else if file_type.is_symlink() {
                FileType::Symlink
            } else {
                FileType::Unknown
            };

            #[cfg(unix)]
            {
                result.push((entry.file_name().into_vec().into(), val));
            }
            #[cfg(not(unix))]
            {
                result.push((
                    entry.file_name().to_string_lossy().as_bytes().to_vec().into(),
                    val,
                ));
            }
        }

        Ok(result)
    }

    fn import_path(&self, path: &Path) -> io::Result<PathBuf> {
        // If already in the store, return as-is
        if path.starts_with(STORE_DIR) {
            return Ok(path.to_path_buf());
        }

        self.import_to_store(path)
    }

    fn store_dir(&self) -> Option<String> {
        Some(STORE_DIR.to_string())
    }

    fn get_env(&self, key: &OsStr) -> Option<OsString> {
        std::env::var_os(key)
    }
}

// Allow SnixRedoxIO to be used as Box<dyn EvalIO> via AsRef
impl AsRef<dyn EvalIO> for SnixRedoxIO {
    fn as_ref(&self) -> &(dyn EvalIO + 'static) {
        self
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────

/// Sanitize a filename for use as a Nix store path name.
/// Nix store names allow: [a-zA-Z0-9+\-._?=] and must not start with '.'.
fn sanitize_store_name(name: &str) -> String {
    let sanitized: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "-_+=.?".contains(c) {
                c
            } else {
                '-'
            }
        })
        .collect();

    // Must not start with '.'
    if sanitized.starts_with('.') {
        format!("_{}", &sanitized[1..])
    } else if sanitized.is_empty() {
        "source".to_string()
    } else {
        sanitized
    }
}

/// Recursively copy a path (file, directory, or symlink) to a destination.
fn copy_path(src: &Path, dest: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(src)?;

    if meta.is_symlink() {
        let target = fs::read_link(src)?;
        std::os::unix::fs::symlink(&target, dest)?;
    } else if meta.is_file() {
        fs::copy(src, dest)?;
    } else if meta.is_dir() {
        fs::create_dir(dest)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            copy_path(&entry.path(), &dest.join(entry.file_name()))?;
        }
    }

    Ok(())
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::known_paths::KnownPaths;
    use std::cell::RefCell;

    fn make_io() -> (SnixRedoxIO, Rc<SnixRedoxState>) {
        let state = Rc::new(SnixRedoxState {
            known_paths: RefCell::new(KnownPaths::default()),
        });
        let io = SnixRedoxIO::new(Rc::clone(&state));
        (io, state)
    }

    // ── store_dir ──────────────────────────────────────────────────────

    #[test]
    fn store_dir_returns_nix_store() {
        let (io, _) = make_io();
        assert_eq!(io.store_dir(), Some("/nix/store".to_string()));
    }

    // ── get_env ────────────────────────────────────────────────────────

    #[test]
    fn get_env_returns_existing() {
        let (io, _) = make_io();
        // PATH should always be set
        let result = io.get_env(OsStr::new("PATH"));
        assert!(result.is_some());
    }

    #[test]
    fn get_env_returns_none_for_missing() {
        let (io, _) = make_io();
        let result = io.get_env(OsStr::new("SNIX_NONEXISTENT_VAR_FOR_TESTING"));
        assert!(result.is_none());
    }

    // ── path_exists ────────────────────────────────────────────────────

    #[test]
    fn path_exists_true_for_existing() {
        let (io, _) = make_io();
        assert!(io.path_exists(Path::new("/")).unwrap());
    }

    #[test]
    fn path_exists_false_for_missing() {
        let (io, _) = make_io();
        assert!(!io.path_exists(Path::new("/nonexistent-snix-test-path")).unwrap());
    }

    #[test]
    fn path_exists_for_temp_file() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("exists.txt");
        fs::write(&file, "hi").unwrap();

        let (io, _) = make_io();
        assert!(io.path_exists(&file).unwrap());
    }

    // ── open ───────────────────────────────────────────────────────────

    #[test]
    fn open_reads_file() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("hello.txt");
        fs::write(&file, "hello snix").unwrap();

        let (io, _) = make_io();
        let mut reader = io.open(&file).unwrap();
        let mut content = String::new();
        io::Read::read_to_string(&mut reader, &mut content).unwrap();
        assert_eq!(content, "hello snix");
    }

    #[test]
    fn open_missing_file_errors() {
        let (io, _) = make_io();
        let result = io.open(Path::new("/nonexistent-snix-test-file"));
        assert!(result.is_err());
    }

    // ── file_type ──────────────────────────────────────────────────────

    #[test]
    fn file_type_regular() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("reg");
        fs::write(&file, "data").unwrap();

        let (io, _) = make_io();
        let ft = io.file_type(&file).unwrap();
        assert!(matches!(ft, FileType::Regular));
    }

    #[test]
    fn file_type_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("subdir");
        fs::create_dir(&dir).unwrap();

        let (io, _) = make_io();
        let ft = io.file_type(&dir).unwrap();
        assert!(matches!(ft, FileType::Directory));
    }

    #[test]
    fn file_type_symlink() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("target");
        fs::write(&target, "x").unwrap();
        let link = tmp.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let (io, _) = make_io();
        let ft = io.file_type(&link).unwrap();
        // symlink_metadata returns symlink type
        assert!(matches!(ft, FileType::Symlink));
    }

    // ── read_dir ───────────────────────────────────────────────────────

    #[test]
    fn read_dir_lists_entries() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("a.txt"), "a").unwrap();
        fs::write(tmp.path().join("b.txt"), "b").unwrap();
        fs::create_dir(tmp.path().join("subdir")).unwrap();

        let (io, _) = make_io();
        let entries = io.read_dir(tmp.path()).unwrap();
        assert_eq!(entries.len(), 3);

        let names: Vec<String> = entries
            .iter()
            .map(|(name, _)| String::from_utf8_lossy(name).to_string())
            .collect();
        assert!(names.contains(&"a.txt".to_string()));
        assert!(names.contains(&"b.txt".to_string()));
        assert!(names.contains(&"subdir".to_string()));
    }

    #[test]
    fn read_dir_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let empty = tmp.path().join("empty");
        fs::create_dir(&empty).unwrap();

        let (io, _) = make_io();
        let entries = io.read_dir(&empty).unwrap();
        assert!(entries.is_empty());
    }

    // ── import_path ────────────────────────────────────────────────────

    #[test]
    fn import_path_store_passthrough() {
        let (io, _) = make_io();
        let store_path = Path::new("/nix/store/abc123-something");
        let result = io.import_path(store_path).unwrap();
        assert_eq!(result, store_path);
    }

    // ── sanitize_store_name ────────────────────────────────────────────

    #[test]
    fn sanitize_name_passthrough() {
        assert_eq!(sanitize_store_name("hello-world"), "hello-world");
        assert_eq!(sanitize_store_name("foo_bar.nix"), "foo_bar.nix");
    }

    #[test]
    fn sanitize_name_replaces_invalid() {
        assert_eq!(sanitize_store_name("my file (1)"), "my-file--1-");
        assert_eq!(sanitize_store_name("src/main.rs"), "src-main.rs");
    }

    #[test]
    fn sanitize_name_dot_prefix() {
        assert_eq!(sanitize_store_name(".hidden"), "_hidden");
    }

    #[test]
    fn sanitize_name_empty() {
        assert_eq!(sanitize_store_name(""), "source");
    }

    // ── extract_store_path ─────────────────────────────────────────────

    #[test]
    fn extract_store_path_simple() {
        let (io, _) = make_io();
        let path = Path::new("/nix/store/5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r-hello-1.0");
        let sp = io.extract_store_path(path);
        assert!(sp.is_some());
        assert_eq!(sp.unwrap().to_absolute_path(), path.to_str().unwrap());
    }

    #[test]
    fn extract_store_path_with_subpath() {
        let (io, _) = make_io();
        let path = Path::new("/nix/store/5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r-hello-1.0/bin/hello");
        let sp = io.extract_store_path(path);
        assert!(sp.is_some());
        assert_eq!(
            sp.unwrap().to_absolute_path(),
            "/nix/store/5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r-hello-1.0"
        );
    }

    #[test]
    fn extract_store_path_non_store() {
        let (io, _) = make_io();
        assert!(io.extract_store_path(Path::new("/tmp/foo")).is_none());
    }

    #[test]
    fn extract_store_path_too_short() {
        let (io, _) = make_io();
        assert!(io.extract_store_path(Path::new("/nix/store/short")).is_none());
    }

    // ── copy_path ──────────────────────────────────────────────────────

    #[test]
    fn copy_path_file() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src.txt");
        fs::write(&src, "content").unwrap();
        let dest = tmp.path().join("dest.txt");

        copy_path(&src, &dest).unwrap();
        assert_eq!(fs::read_to_string(&dest).unwrap(), "content");
    }

    #[test]
    fn copy_path_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let src_dir = tmp.path().join("src");
        fs::create_dir(&src_dir).unwrap();
        fs::write(src_dir.join("a.txt"), "alpha").unwrap();
        fs::write(src_dir.join("b.txt"), "bravo").unwrap();

        let dest_dir = tmp.path().join("dest");
        copy_path(&src_dir, &dest_dir).unwrap();

        assert!(dest_dir.is_dir());
        assert_eq!(fs::read_to_string(dest_dir.join("a.txt")).unwrap(), "alpha");
        assert_eq!(fs::read_to_string(dest_dir.join("b.txt")).unwrap(), "bravo");
    }

    #[test]
    fn copy_path_symlink() {
        let tmp = tempfile::tempdir().unwrap();
        let link = tmp.path().join("link");
        std::os::unix::fs::symlink("/somewhere/else", &link).unwrap();

        let dest = tmp.path().join("link_copy");
        copy_path(&link, &dest).unwrap();

        assert!(dest.symlink_metadata().unwrap().is_symlink());
        assert_eq!(fs::read_link(&dest).unwrap().to_str().unwrap(), "/somewhere/else");
    }

    // ── Eval integration with SnixRedoxIO ──────────────────────────────

    #[test]
    fn eval_with_io_store_dir() {
        // builtins.storeDir should return /nix/store when using SnixRedoxIO
        let result = eval_with_snix_io("builtins.storeDir").unwrap();
        assert_eq!(result, "\"/nix/store\"");
    }

    #[test]
    fn eval_with_io_derivation() {
        // derivationStrict should work through SnixRedoxIO
        let result = eval_with_snix_io(
            r#"(derivation { name = "io-test"; builder = "/bin/sh"; system = "x86_64-linux"; }).outPath"#,
        )
        .unwrap();
        assert!(result.starts_with("\"/nix/store/"));
        assert!(result.contains("-io-test\""));
    }

    #[test]
    fn eval_with_io_path_exists_true() {
        let result = eval_with_snix_io("builtins.pathExists /.")
            .unwrap();
        assert_eq!(result, "true");
    }

    #[test]
    fn eval_with_io_path_exists_false() {
        let result = eval_with_snix_io(
            r#"builtins.pathExists /nonexistent-snix-test-path-12345"#,
        )
        .unwrap();
        assert_eq!(result, "false");
    }

    #[test]
    fn eval_with_io_read_dir() {
        // Read the root directory — should have entries
        let result = eval_with_snix_io("builtins.attrNames (builtins.readDir /tmp)")
            .unwrap();
        // Result is a list; just verify it's not an error
        assert!(result.starts_with("["), "result: {result}");
    }

    /// Helper: evaluate an expression using SnixRedoxIO
    fn eval_with_snix_io(expr: &str) -> Result<String, Box<dyn std::error::Error>> {
        use crate::derivation_builtins::derivation_builtins;
        use crate::known_paths::KnownPaths;
        use snix_eval::Evaluation;

        let state = Rc::new(SnixRedoxState {
            known_paths: RefCell::new(KnownPaths::default()),
        });

        let io = SnixRedoxIO::new(Rc::clone(&state));

        let eval = Evaluation::builder_pure()
            .enable_impure(Some(Box::new(io) as Box<dyn EvalIO>))
            .add_builtins(derivation_builtins::builtins(Rc::clone(&state)))
            .add_src_builtin("derivation", include_str!("derivation.nix"))
            .build();

        let result = eval.evaluate(expr, None);

        if !result.errors.is_empty() {
            let errors: Vec<String> = result.errors.iter().map(|e| format!("{e}")).collect();
            return Err(errors.join("\n").into());
        }

        match result.value {
            Some(v) => Ok(format!("{v}")),
            None => Err("no value produced".into()),
        }
    }
}
