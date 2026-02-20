//! Local Nix store management for Redox OS.
//!
//! Manages `/nix/store` with a JSON-based metadata database.
//! Provides:
//!   - Store path verification
//!   - Closure computation (transitive dependency graphs)
//!   - GC roots (symlinks protecting paths from collection)
//!   - Garbage collection (mark-and-sweep)
//!
//! Layout:
//! ```text
//! /nix/store/              — store paths (the data)
//! /nix/var/snix/
//!   pathinfo/{hash}.json   — per-path metadata
//!   gcroots/               — symlinks to live roots
//! ```

use std::collections::{BTreeSet, VecDeque};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use nix_compat::store_path::{StorePath, STORE_DIR};

use crate::pathinfo::{self, PathInfo, PathInfoDb, PathInfoError, SNIX_VAR_DIR};

// ===== Closure Computation =====

/// The transitive closure of a store path — all paths reachable through references.
#[derive(Debug)]
pub struct Closure {
    /// Every path in the closure (including the root), sorted.
    pub paths: BTreeSet<String>,
    /// Total NAR size of the closure in bytes.
    pub total_nar_size: u64,
}

/// Compute the transitive closure of a store path via BFS over references.
///
/// Returns an error if the path (or any of its references) is not registered.
pub fn compute_closure(
    db: &PathInfoDb,
    root: &str,
) -> Result<Closure, Box<dyn std::error::Error>> {
    let mut visited = BTreeSet::new();
    let mut queue = VecDeque::new();
    let mut total_nar_size: u64 = 0;

    queue.push_back(root.to_string());

    while let Some(path) = queue.pop_front() {
        if visited.contains(&path) {
            continue;
        }

        let info = db
            .get(&path)?
            .ok_or_else(|| format!("path not registered: {path}"))?;

        total_nar_size += info.nar_size;
        visited.insert(path);

        for r in &info.references {
            if !visited.contains(r) {
                queue.push_back(r.clone());
            }
        }
    }

    Ok(Closure {
        paths: visited,
        total_nar_size,
    })
}

// ===== GC Roots =====

/// Manages GC root symlinks in `/nix/var/snix/gcroots/`.
pub struct GcRoots {
    roots_dir: PathBuf,
}

/// A single GC root entry.
#[derive(Debug)]
pub struct GcRoot {
    /// Symbolic name (e.g., "my-app", "system-profile")
    pub name: String,
    /// Target store path the symlink points to
    pub target: String,
}

impl GcRoots {
    /// Open (and create) the default GC roots directory.
    pub fn open() -> io::Result<Self> {
        Self::open_at(Path::new(SNIX_VAR_DIR).join("gcroots"))
    }

    /// Open at a custom path (for testing).
    pub fn open_at(roots_dir: PathBuf) -> io::Result<Self> {
        fs::create_dir_all(&roots_dir)?;
        Ok(Self { roots_dir })
    }

    /// Add a GC root.  Creates a symlink `name → store_path`.
    pub fn add_root(
        &self,
        name: &str,
        store_path: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        // Validate the store path format
        StorePath::<String>::from_absolute_path(store_path.as_bytes())
            .map_err(|e| format!("invalid store path: {e}"))?;

        let link = self.roots_dir.join(name);
        // Remove existing symlink if present
        if link.symlink_metadata().is_ok() {
            fs::remove_file(&link)?;
        }
        std::os::unix::fs::symlink(store_path, &link)?;
        Ok(())
    }

    /// Remove a GC root by name.
    pub fn remove_root(&self, name: &str) -> Result<(), Box<dyn std::error::Error>> {
        let link = self.roots_dir.join(name);
        if link.symlink_metadata().is_ok() {
            fs::remove_file(&link)?;
            Ok(())
        } else {
            Err(format!("GC root not found: {name}").into())
        }
    }

    /// List all GC roots (name → target).
    pub fn list_roots(&self) -> Result<Vec<GcRoot>, Box<dyn std::error::Error>> {
        let mut roots = Vec::new();
        for entry in fs::read_dir(&self.roots_dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().to_string();
            if let Ok(target) = fs::read_link(entry.path()) {
                roots.push(GcRoot {
                    name,
                    target: target.to_string_lossy().to_string(),
                });
            }
        }
        roots.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(roots)
    }

    /// Compute the set of all store paths reachable from any GC root.
    ///
    /// For each root symlink, reads the target store path, then computes
    /// its transitive closure through the PathInfo database.
    pub fn compute_live_set(
        &self,
        db: &PathInfoDb,
    ) -> Result<BTreeSet<String>, Box<dyn std::error::Error>> {
        let mut live = BTreeSet::new();

        for root in self.list_roots()? {
            // Skip dangling roots (target no longer registered)
            if !db.is_registered(&root.target) {
                eprintln!(
                    "warning: GC root '{}' points to unregistered path: {}",
                    root.name, root.target
                );
                continue;
            }
            match compute_closure(db, &root.target) {
                Ok(closure) => {
                    live.extend(closure.paths);
                }
                Err(e) => {
                    eprintln!(
                        "warning: cannot compute closure for root '{}': {e}",
                        root.name
                    );
                }
            }
        }

        Ok(live)
    }
}

// ===== Garbage Collection =====

/// Statistics from a GC run.
#[derive(Debug, Default)]
pub struct GcStats {
    /// Number of store paths deleted (or would-be-deleted in dry run).
    pub paths_deleted: u32,
    /// Bytes freed on disk.
    pub bytes_freed: u64,
    /// Number of store paths kept (live).
    pub paths_kept: u32,
}

/// Run garbage collection.
///
/// Algorithm (mark-and-sweep):
/// 1. Enumerate all registered store paths.
/// 2. Compute the live set from GC roots.
/// 3. Dead set = all − live.
/// 4. Delete each dead path (store directory + pathinfo).
///
/// With `dry_run = true`, reports what *would* be deleted without removing anything.
pub fn garbage_collect(
    db: &PathInfoDb,
    gc_roots: &GcRoots,
    dry_run: bool,
) -> Result<GcStats, Box<dyn std::error::Error>> {
    let all_paths = db.all_paths_set()?;
    let live_set = gc_roots.compute_live_set(db)?;

    let dead_set: BTreeSet<_> = all_paths.difference(&live_set).cloned().collect();

    let mut stats = GcStats {
        paths_kept: live_set.len() as u32,
        ..Default::default()
    };

    if dead_set.is_empty() {
        return Ok(stats);
    }

    for path in &dead_set {
        // Compute disk size before deletion
        let size = path_size(Path::new(path)).unwrap_or(0);

        if dry_run {
            let human = human_size(size);
            eprintln!("would delete: {path} ({human})");
        } else {
            // Remove from filesystem first
            let p = Path::new(path);
            if p.exists() {
                if p.is_dir() {
                    fs::remove_dir_all(p)?;
                } else {
                    fs::remove_file(p)?;
                }
            }
            // Then remove metadata
            db.delete(path)?;
        }

        stats.paths_deleted += 1;
        stats.bytes_freed += size;
    }

    Ok(stats)
}

// ===== Existing Store Functions (updated) =====

/// Ensure the /nix/store directory exists.
pub fn ensure_store_dir() -> io::Result<()> {
    let store = Path::new(STORE_DIR);
    if !store.exists() {
        fs::create_dir_all(store)?;
        eprintln!("created {STORE_DIR}");
    }
    Ok(())
}

/// Register a newly-fetched store path in the database.
pub fn register_path(
    db: &PathInfoDb,
    store_path: &str,
    nar_hash: &str,
    nar_size: u64,
    references: Vec<String>,
    signatures: Vec<String>,
) -> Result<(), PathInfoError> {
    let info = PathInfo {
        store_path: store_path.to_string(),
        nar_hash: nar_hash.to_string(),
        nar_size,
        references,
        deriver: None,
        registration_time: pathinfo::current_timestamp(),
        signatures,
    };
    db.register(&info)
}

/// Verify the local store — check that all store paths are parseable.
pub fn verify() -> Result<(), Box<dyn std::error::Error>> {
    let store = Path::new(STORE_DIR);

    if !store.exists() {
        eprintln!("no store at {STORE_DIR}");
        return Ok(());
    }

    let mut count = 0;
    let mut errors = 0;

    for entry in fs::read_dir(store)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        let full_path = format!("{STORE_DIR}/{name_str}");
        match StorePath::<String>::from_absolute_path(full_path.as_bytes()) {
            Ok(_sp) => {
                count += 1;
            }
            Err(e) => {
                errors += 1;
                eprintln!("  invalid store path: {name_str}: {e}");
            }
        }
    }

    println!("store: {count} paths, {errors} errors");
    Ok(())
}

// ===== CLI Handlers =====

/// `snix store list` — list all registered store paths with sizes.
pub fn list_registered() -> Result<(), Box<dyn std::error::Error>> {
    let db = PathInfoDb::open()?;
    let paths = db.list_paths()?;

    if paths.is_empty() {
        println!("No registered store paths.");
        println!("Hint: use 'snix fetch' to download packages from a binary cache.");
        return Ok(());
    }

    let mut total_nar: u64 = 0;
    let mut total_disk: u64 = 0;

    for path in &paths {
        let nar_size = db
            .get(path)?
            .map(|i| i.nar_size)
            .unwrap_or(0);
        let disk_size = path_size(Path::new(path)).unwrap_or(0);

        total_nar += nar_size;
        total_disk += disk_size;

        let refs = db
            .get(path)?
            .map(|i| i.references.len())
            .unwrap_or(0);

        println!(
            "{path}  (NAR {}, disk {}, {} refs)",
            human_size(nar_size),
            human_size(disk_size),
            refs,
        );
    }

    println!();
    println!(
        "{} paths, NAR total {}, disk total {}",
        paths.len(),
        human_size(total_nar),
        human_size(total_disk),
    );

    Ok(())
}

/// `snix store info PATH` — show metadata for a single path.
pub fn show_info(store_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let db = PathInfoDb::open()?;
    let info = db
        .get(store_path)?
        .ok_or_else(|| format!("path not registered: {store_path}"))?;

    println!("StorePath:    {}", info.store_path);
    println!("NarHash:      {}", info.nar_hash);
    println!("NarSize:      {} ({})", info.nar_size, human_size(info.nar_size));
    println!("Registered:   {}", info.registration_time);
    if let Some(ref drv) = info.deriver {
        println!("Deriver:      {drv}");
    }
    if !info.signatures.is_empty() {
        println!("Signatures:");
        for sig in &info.signatures {
            println!("  {sig}");
        }
    }
    println!("References:   {}", info.references.len());
    for r in &info.references {
        let marker = if r == &info.store_path { " (self)" } else { "" };
        println!("  {r}{marker}");
    }

    // Disk usage
    let disk = path_size(Path::new(&info.store_path)).unwrap_or(0);
    println!("Disk:         {}", human_size(disk));

    Ok(())
}

/// `snix store closure PATH` — show the transitive closure.
pub fn show_closure(store_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let db = PathInfoDb::open()?;
    let closure = compute_closure(&db, store_path)?;

    for path in &closure.paths {
        let size = db.get(path)?.map(|i| i.nar_size).unwrap_or(0);
        println!("{path}  ({})", human_size(size));
    }

    println!();
    println!(
        "Closure: {} paths, {} total NAR size",
        closure.paths.len(),
        human_size(closure.total_nar_size),
    );

    Ok(())
}

/// `snix store gc [--dry-run]` — run garbage collection.
pub fn run_gc(dry_run: bool) -> Result<(), Box<dyn std::error::Error>> {
    let db = PathInfoDb::open()?;
    let gc_roots = GcRoots::open()?;

    let roots = gc_roots.list_roots()?;
    if roots.is_empty() {
        eprintln!("warning: no GC roots — all paths will be collected!");
        eprintln!("Add roots with: snix store add-root NAME STORE_PATH");
        eprintln!();
    }

    let stats = garbage_collect(&db, &gc_roots, dry_run)?;

    if dry_run {
        println!();
        println!(
            "Would free {} ({} paths). {} paths kept.",
            human_size(stats.bytes_freed),
            stats.paths_deleted,
            stats.paths_kept,
        );
    } else if stats.paths_deleted > 0 {
        println!(
            "Freed {} ({} paths deleted, {} kept).",
            human_size(stats.bytes_freed),
            stats.paths_deleted,
            stats.paths_kept,
        );
    } else {
        println!("Nothing to collect. {} paths in use.", stats.paths_kept);
    }

    Ok(())
}

/// `snix store add-root NAME PATH`
pub fn add_root(name: &str, store_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let gc_roots = GcRoots::open()?;
    gc_roots.add_root(name, store_path)?;
    println!("Added GC root: {name} → {store_path}");
    Ok(())
}

/// `snix store remove-root NAME`
pub fn remove_root(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let gc_roots = GcRoots::open()?;
    gc_roots.remove_root(name)?;
    println!("Removed GC root: {name}");
    Ok(())
}

/// `snix store roots` — list all GC roots.
pub fn list_roots() -> Result<(), Box<dyn std::error::Error>> {
    let gc_roots = GcRoots::open()?;
    let roots = gc_roots.list_roots()?;

    if roots.is_empty() {
        println!("No GC roots.");
        println!("Hint: add one with 'snix store add-root NAME STORE_PATH'");
        return Ok(());
    }

    for root in &roots {
        let exists = Path::new(&root.target).exists();
        let marker = if exists { "" } else { " (missing!)" };
        println!("{} → {}{marker}", root.name, root.target);
    }

    println!();
    println!("{} GC roots.", roots.len());
    Ok(())
}

// ===== Helpers =====

/// Get the recursive size of a store path on disk.
pub fn path_size(path: &Path) -> io::Result<u64> {
    if path.is_file() {
        Ok(path.metadata()?.len())
    } else if path.is_dir() {
        let mut total = 0;
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            total += path_size(&entry.path())?;
        }
        Ok(total)
    } else {
        Ok(0)
    }
}

/// Format a byte count for humans.
fn human_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;

    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{bytes} B")
    }
}

/// Check if a store path exists locally.
#[allow(dead_code)]
pub fn path_exists(store_path: &str) -> bool {
    Path::new(store_path).exists()
}

/// List all store paths on the filesystem.
#[allow(dead_code)]
pub fn list_paths() -> io::Result<Vec<PathBuf>> {
    let store = Path::new(STORE_DIR);
    if !store.exists() {
        return Ok(Vec::new());
    }

    let mut paths = Vec::new();
    for entry in fs::read_dir(store)? {
        let entry = entry?;
        paths.push(entry.path());
    }
    paths.sort();
    Ok(paths)
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    // Valid nixbase32 test store paths (alphabet: 0123456789abcdfghijklmnpqrsvwxyz)
    const P_A: &str = "/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-a-1.0";
    const P_B: &str = "/nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-b-1.0";
    const P_C: &str = "/nix/store/3d7lxgskakh8klnz4gydrzk8d6p3rq6r-c-1.0";
    const P_D: &str = "/nix/store/4f6mybrlblj9lmpz5hzfs0l9f7q4sp7s-d-1.0";
    const P_HELLO: &str = "/nix/store/5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r-hello-1.0";
    const P_SHARED: &str = "/nix/store/6h4pzdrnfnl1npqz7j1hs2n1h9s6rp9s-shared-1.0";
    const P_KEEP: &str = "/nix/store/7i3q0fspgpm2pqqz8k2ir3p2i0r7rq0r-keep-1.0";
    const P_DEAD: &str = "/nix/store/8j2r1grqhqn3qqrz9l3js4q3j1s8sp1s-dead-1.0";
    const P_ORPHAN: &str = "/nix/store/9k1s2hsrirp4rrqz0m4kr5r4k2r9rq2r-orphan-1.0";
    const P_V1: &str = "/nix/store/al0r3irsfsq5ssqz1n5ls6s5l3s0rp3s-v1-1.0";
    const P_V2: &str = "/nix/store/bm9s4jssgrr6rrqz2p6mr7r6m4s1rq4r-v2-2.0";
    const P_GONE: &str = "/nix/store/dp7s6lssjss8ssqz4r8ps9s8p6r3rq6r-gone-1.0";

    fn make_db(tmp: &TempDir) -> PathInfoDb {
        PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap()
    }

    fn make_roots(tmp: &TempDir) -> GcRoots {
        GcRoots::open_at(tmp.path().join("gcroots")).unwrap()
    }

    fn register(db: &PathInfoDb, path: &str, refs: Vec<&str>, size: u64) {
        let info = PathInfo {
            store_path: path.to_string(),
            nar_hash: "deadbeef".to_string(),
            nar_size: size,
            references: refs.into_iter().map(String::from).collect(),
            deriver: None,
            registration_time: "2026-01-01T00:00:00Z".to_string(),
            signatures: vec![],
        };
        db.register(&info).unwrap();
    }

    // ===== Closure Tests =====

    #[test]
    fn closure_single_path_no_refs() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);

        register(&db, P_HELLO, vec![], 1000);

        let closure = compute_closure(&db, P_HELLO).unwrap();
        assert_eq!(closure.paths.len(), 1);
        assert!(closure.paths.contains(P_HELLO));
        assert_eq!(closure.total_nar_size, 1000);
    }

    #[test]
    fn closure_chain() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);

        register(&db, P_C, vec![], 100);
        register(&db, P_B, vec![P_C], 200);
        register(&db, P_A, vec![P_B], 300);

        let closure = compute_closure(&db, P_A).unwrap();
        assert_eq!(closure.paths.len(), 3);
        assert!(closure.paths.contains(P_A));
        assert!(closure.paths.contains(P_B));
        assert!(closure.paths.contains(P_C));
        assert_eq!(closure.total_nar_size, 600);
    }

    #[test]
    fn closure_diamond() {
        // a → {b, c}, b → d, c → d
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);

        register(&db, P_D, vec![], 10);
        register(&db, P_C, vec![P_D], 20);
        register(&db, P_B, vec![P_D], 30);
        register(&db, P_A, vec![P_B, P_C], 40);

        let closure = compute_closure(&db, P_A).unwrap();
        assert_eq!(closure.paths.len(), 4);
        // d counted only once
        assert_eq!(closure.total_nar_size, 100);
    }

    #[test]
    fn closure_self_reference() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);

        register(&db, P_A, vec![P_A], 500);

        let closure = compute_closure(&db, P_A).unwrap();
        assert_eq!(closure.paths.len(), 1);
        assert_eq!(closure.total_nar_size, 500);
    }

    #[test]
    fn closure_missing_ref_errors() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);

        register(&db, P_A, vec![P_GONE], 100);

        let result = compute_closure(&db, P_A);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("not registered"));
    }

    // ===== GC Root Tests =====

    #[test]
    fn gc_root_add_and_list() {
        let tmp = TempDir::new().unwrap();
        let roots = make_roots(&tmp);

        roots.add_root("hello", P_HELLO).unwrap();

        let listed = roots.list_roots().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "hello");
        assert_eq!(listed[0].target, P_HELLO);
    }

    #[test]
    fn gc_root_remove() {
        let tmp = TempDir::new().unwrap();
        let roots = make_roots(&tmp);

        roots.add_root("hello", P_HELLO).unwrap();

        roots.remove_root("hello").unwrap();
        let listed = roots.list_roots().unwrap();
        assert!(listed.is_empty());
    }

    #[test]
    fn gc_root_remove_nonexistent_errors() {
        let tmp = TempDir::new().unwrap();
        let roots = make_roots(&tmp);

        let result = roots.remove_root("nope");
        assert!(result.is_err());
    }

    #[test]
    fn gc_root_overwrite() {
        let tmp = TempDir::new().unwrap();
        let roots = make_roots(&tmp);

        roots.add_root("app", P_V1).unwrap();
        roots.add_root("app", P_V2).unwrap();

        let listed = roots.list_roots().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].target, P_V2);
    }

    #[test]
    fn gc_root_invalid_store_path_errors() {
        let tmp = TempDir::new().unwrap();
        let roots = make_roots(&tmp);

        let result = roots.add_root("bad", "/tmp/not-a-store-path");
        assert!(result.is_err());
    }

    // ===== Live Set Tests =====

    #[test]
    fn live_set_empty_roots() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);
        let roots = make_roots(&tmp);

        let live = roots.compute_live_set(&db).unwrap();
        assert!(live.is_empty());
    }

    #[test]
    fn live_set_single_root_with_deps() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);
        let roots = make_roots(&tmp);

        register(&db, P_B, vec![], 100);
        register(&db, P_A, vec![P_B], 200);

        roots.add_root("app", P_A).unwrap();

        let live = roots.compute_live_set(&db).unwrap();
        assert_eq!(live.len(), 2);
        assert!(live.contains(P_A));
        assert!(live.contains(P_B));
    }

    #[test]
    fn live_set_multiple_roots_union() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);
        let roots = make_roots(&tmp);

        register(&db, P_SHARED, vec![], 50);
        register(&db, P_A, vec![P_SHARED], 100);
        register(&db, P_B, vec![P_SHARED], 200);

        roots.add_root("app-a", P_A).unwrap();
        roots.add_root("app-b", P_B).unwrap();

        let live = roots.compute_live_set(&db).unwrap();
        assert_eq!(live.len(), 3); // a, b, shared
    }

    // ===== Garbage Collection Tests =====

    #[test]
    fn gc_nothing_to_collect() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);
        let roots = make_roots(&tmp);

        register(&db, P_A, vec![], 100);
        roots.add_root("keep", P_A).unwrap();

        let stats = garbage_collect(&db, &roots, false).unwrap();
        assert_eq!(stats.paths_deleted, 0);
        assert_eq!(stats.paths_kept, 1);
    }

    #[test]
    fn gc_collects_unreferenced() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);
        let roots = make_roots(&tmp);

        register(&db, P_KEEP, vec![], 100);
        register(&db, P_DEAD, vec![], 200);
        roots.add_root("keep", P_KEEP).unwrap();

        // Dry run first
        let dry = garbage_collect(&db, &roots, true).unwrap();
        assert_eq!(dry.paths_deleted, 1);
        assert_eq!(dry.paths_kept, 1);

        // Paths still registered after dry run
        assert!(db.is_registered(P_DEAD));

        // Real GC
        let stats = garbage_collect(&db, &roots, false).unwrap();
        assert_eq!(stats.paths_deleted, 1);
        assert_eq!(stats.paths_kept, 1);

        // Dead path is gone from the database
        assert!(!db.is_registered(P_DEAD));
        // Keep path still there
        assert!(db.is_registered(P_KEEP));
    }

    #[test]
    fn gc_preserves_transitive_deps() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);
        let roots = make_roots(&tmp);

        register(&db, P_B, vec![], 100);
        register(&db, P_A, vec![P_B], 200);
        register(&db, P_ORPHAN, vec![], 50);

        roots.add_root("app", P_A).unwrap();

        let stats = garbage_collect(&db, &roots, false).unwrap();
        assert_eq!(stats.paths_deleted, 1); // only orphan
        assert_eq!(stats.paths_kept, 2);    // a + b

        assert!(db.is_registered(P_A));
        assert!(db.is_registered(P_B));
        assert!(!db.is_registered(P_ORPHAN));
    }

    #[test]
    fn gc_no_roots_collects_everything() {
        let tmp = TempDir::new().unwrap();
        let db = make_db(&tmp);
        let roots = make_roots(&tmp);

        register(&db, P_A, vec![], 100);
        register(&db, P_B, vec![], 200);

        let stats = garbage_collect(&db, &roots, false).unwrap();
        assert_eq!(stats.paths_deleted, 2);
        assert_eq!(stats.paths_kept, 0);
    }

    // ===== Helper Tests =====

    #[test]
    fn human_size_formatting() {
        assert_eq!(human_size(0), "0 B");
        assert_eq!(human_size(512), "512 B");
        assert_eq!(human_size(1024), "1.0 KB");
        assert_eq!(human_size(1536), "1.5 KB");
        assert_eq!(human_size(1048576), "1.0 MB");
        assert_eq!(human_size(1073741824), "1.0 GB");
    }

    #[test]
    fn path_size_file() {
        let tmp = TempDir::new().unwrap();
        let file_path = tmp.path().join("test.txt");
        fs::write(&file_path, b"hello world").unwrap();

        let size = path_size(&file_path).unwrap();
        assert_eq!(size, 11);
    }

    #[test]
    fn path_size_dir() {
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("a.txt"), b"hello").unwrap();
        fs::write(tmp.path().join("b.txt"), b"world").unwrap();

        let subdir = tmp.path().join("sub");
        fs::create_dir(&subdir).unwrap();
        fs::write(subdir.join("c.txt"), b"test").unwrap();

        let total = path_size(tmp.path()).unwrap();
        assert_eq!(total, 14);
    }

    #[test]
    fn path_size_empty() {
        let tmp = TempDir::new().unwrap();
        assert_eq!(path_size(tmp.path()).unwrap(), 0);
    }
}
