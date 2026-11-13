//! Native compatibility commands used by Nixtamal. This is deliberately not a
//! second evaluator or store: aliases share Snix's evaluator, NAR writer,
//! fetchers, path database, builder and garbage collector.

use std::collections::BTreeSet;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use clap::{Parser, Subcommand};
use nix_compat::derivation::Derivation;
use nix_compat::nixhash::{CAHash, HashAlgo, NixHash};
use nix_compat::store_path::{build_ca_path, validate_name, StorePath, STORE_DIR};
use sha2::{Digest, Sha256, Sha512};
use snix_glue::known_paths::KnownPaths;

use crate::pathinfo::PathInfoDb;

type Result<T, E = Box<dyn std::error::Error>> = std::result::Result<T, E>;

#[derive(Clone, Copy, Debug)]
enum Algorithm {
    Sha256,
    Sha512,
}

impl std::str::FromStr for Algorithm {
    type Err = String;
    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "sha256" => Ok(Self::Sha256),
            "sha512" => Ok(Self::Sha512),
            "blake3" => Err("BLAKE3 content addressing is not supported by this Snix nix-compat version; use sha256 or sha512".into()),
            _ => Err(format!("unsupported hash algorithm '{value}'; use sha256 or sha512")),
        }
    }
}
impl Algorithm {
    fn nix(self) -> HashAlgo {
        match self {
            Self::Sha256 => HashAlgo::Sha256,
            Self::Sha512 => HashAlgo::Sha512,
        }
    }
}

#[derive(Parser)]
#[command(
    name = "nix-prefetch-url",
    about = "Snix native URL prefetch compatibility"
)]
struct PrefetchUrl {
    url: String,
    #[arg(long)]
    print_path: bool,
    #[arg(long)]
    unpack: bool,
    #[arg(long = "type", default_value = "sha256")]
    algorithm: Algorithm,
    #[arg(long)]
    name: Option<String>,
}

#[derive(Parser)]
#[command(name = "nix-hash", about = "Snix native hash conversion")]
struct HashArgs {
    #[arg(long, required = true)]
    to_sri: bool,
    #[arg(long = "type")]
    algorithm: Algorithm,
    hash: String,
}

#[derive(Parser)]
#[command(
    name = "nix-prefetch-git",
    about = "Snix native Git prefetch compatibility"
)]
struct PrefetchGit {
    #[arg(long = "no-deepClone")]
    no_deep_clone: bool,
    #[arg(long)]
    quiet: bool,
    #[arg(long)]
    url: String,
    #[arg(long)]
    name: Option<String>,
    #[arg(long)]
    rev: String,
    #[arg(long)]
    fetch_submodules: bool,
    #[arg(long)]
    fetch_lfs: bool,
}

#[derive(Parser)]
#[command(name = "nix-store", about = "Snix native store compatibility")]
struct StoreArgs {
    #[arg(long)]
    indirect: bool,
    #[arg(long)]
    add_root: Option<PathBuf>,
    #[arg(long)]
    realize: String,
}

#[derive(Parser)]
#[command(
    name = "nix-instantiate",
    about = "Snix native derivation instantiation"
)]
struct InstantiateArgs {
    #[arg(long)]
    impure: bool,
    #[arg(long)]
    expr: String,
}

#[derive(Parser)]
#[command(
    name = "nix",
    about = "Snix native Nix command compatibility",
    disable_version_flag = true
)]
struct NixArgs {
    #[arg(long)]
    version: bool,
    #[command(subcommand)]
    command: Option<NixCommand>,
}
#[derive(Subcommand)]
enum NixCommand {
    Hash {
        #[command(subcommand)]
        command: HashCommand,
    },
    Eval {
        #[arg(long)]
        expr: String,
        #[arg(long)]
        impure: bool,
        #[arg(long)]
        raw: bool,
    },
}
#[derive(Subcommand)]
enum HashCommand {
    File {
        #[arg(long = "type", default_value = "sha256")]
        algorithm: Algorithm,
        path: PathBuf,
    },
}

/// Called before the ordinary snix parser, and only claims known basenames.
/// All output is flushed before main exits (important on native Redox).
pub fn dispatch() -> Option<Result<()>> {
    let mut arguments = std::env::args_os();
    let program = arguments.next()?;
    let name = match Path::new(&program).file_name()?.to_str()? {
        "nix" => "nix",
        "nix-hash" => "nix-hash",
        "nix-prefetch-url" => "nix-prefetch-url",
        "nix-prefetch-git" => "nix-prefetch-git",
        "nix-store" => "nix-store",
        "nix-instantiate" => "nix-instantiate",
        _ => return None,
    };
    let args = std::iter::once(program).chain(arguments);
    Some((|| {
        match name {
            "nix-prefetch-url" => prefetch_url(PrefetchUrl::try_parse_from(args)?),
            "nix-prefetch-git" => prefetch_git(PrefetchGit::try_parse_from(args)?),
            "nix-hash" => {
                let options = HashArgs::try_parse_from(args)?;
                let hash = NixHash::from_str(&options.hash, Some(options.algorithm.nix()))?;
                println!("{}", hash.to_sri_string());
                Ok(())
            }
            "nix-store" => store(StoreArgs::try_parse_from(args)?),
            "nix-instantiate" => instantiate(InstantiateArgs::try_parse_from(args)?),
            "nix" => {
                let options = NixArgs::try_parse_from(args)?;
                if options.version {
                    if options.command.is_some() {
                        return Err("--version cannot be combined with a command".into());
                    }
                    println!(
                        "snix {} (native Nix command compatibility)",
                        env!("CARGO_PKG_VERSION")
                    );
                    return Ok(());
                }
                match options
                    .command
                    .ok_or("expected a Snix compatibility command")?
                {
                    NixCommand::Hash {
                        command: HashCommand::File { algorithm, path },
                    } => {
                        println!("{}", hash_file(&path, algorithm)?.to_sri_string());
                        Ok(())
                    }
                    NixCommand::Eval { expr, raw, .. } => crate::eval::run(Some(expr), None, raw),
                }
            }
            _ => unreachable!(),
        }?;
        io::stdout().flush()?;
        Ok(())
    })())
}

// A private directory on the store filesystem makes publication an atomic
// rename. Exclusive creation and RAII cleanup avoid trusting stale partials.
struct Staging(PathBuf);
impl Staging {
    fn new(parent: &Path) -> io::Result<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        fs::create_dir_all(parent)?;
        loop {
            let path = parent.join(format!(
                ".snix-prefetch-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        }
    }
    fn payload(&self) -> PathBuf {
        self.0.join("source")
    }
}
impl Drop for Staging {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct HashWriter {
    sha256: Sha256,
    sha512: Option<Sha512>,
    size: u64,
}
impl HashWriter {
    fn new(algorithm: Algorithm) -> Self {
        Self {
            sha256: Sha256::new(),
            sha512: matches!(algorithm, Algorithm::Sha512).then(Sha512::new),
            size: 0,
        }
    }
    fn finish(self) -> (NixHash, NixHash, u64) {
        let nar = NixHash::Sha256(self.sha256.finalize().into());
        let selected = match self.sha512 {
            Some(hash) => NixHash::Sha512(Box::new(hash.finalize().into())),
            None => nar.clone(),
        };
        (selected, nar, self.size)
    }
}
impl Write for HashWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.sha256.update(bytes);
        if let Some(hash) = &mut self.sha512 {
            hash.update(bytes);
        }
        self.size += bytes.len() as u64;
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
fn hash_file(path: &Path, algorithm: Algorithm) -> Result<NixHash> {
    fn digest_file<D: Digest>(path: &Path) -> io::Result<sha2::digest::Output<D>> {
        let mut reader = fs::File::open(path)?;
        let mut digest = D::new();
        let mut buffer = [0u8; 65536];
        loop {
            let size = reader.read(&mut buffer)?;
            if size == 0 {
                return Ok(digest.finalize());
            }
            digest.update(&buffer[..size]);
        }
    }
    Ok(match algorithm {
        Algorithm::Sha256 => NixHash::Sha256(digest_file::<Sha256>(path)?.into()),
        Algorithm::Sha512 => NixHash::Sha512(Box::new(digest_file::<Sha512>(path)?.into())),
    })
}
fn hash_nar(path: &Path, algorithm: Algorithm) -> Result<(NixHash, NixHash, u64)> {
    let mut writer = HashWriter::new(algorithm);
    let node = nix_compat::nar::writer::open(&mut writer)?;
    crate::local_build::write_path_to_nar(node, path)?;
    Ok(writer.finish())
}

fn url_name(url: &str) -> Result<String> {
    let fetch = snix_glue::fetchers::Fetch::URL {
        url: url.parse()?,
        exp_hash: None,
    };
    let snix_glue::fetchers::Fetch::URL { url, .. } = fetch else {
        unreachable!()
    };
    let name = url
        .path()
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("");
    validate_name(name)?;
    Ok(name.to_owned())
}

fn git_name(url: &str, revision: &str) -> Result<String> {
    // nix-prefetch-git's url_to_name: basename without .git, with a
    // seven-character suffix only for simple lowercase alphanumeric refs.
    let basename = url.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let basename = basename.strip_suffix(".git").unwrap_or(basename);
    let basename = basename.split(':').nth(1).unwrap_or(basename);
    let name = if !revision.is_empty()
        && revision
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    {
        format!("{basename}-{}", &revision[..revision.len().min(7)])
    } else {
        basename.to_owned()
    };
    validate_name(&name)?;
    Ok(name)
}

fn prefetch_url(options: PrefetchUrl) -> Result<()> {
    let name = match options.name {
        Some(name) => name,
        None => url_name(&options.url)?,
    };
    validate_name(&name)?;
    let staging = Staging::new(Path::new(STORE_DIR))?;
    let payload = staging.payload();
    let out = payload.to_str().ok_or("non-UTF-8 staging path")?;
    if options.unpack {
        crate::fetchers::fetch_and_unpack(&options.url, out)?;
    } else {
        crate::fetchers::fetch_flat(&options.url, out)?;
    }
    let (recursive, nar_hash, size) = hash_nar(
        &payload,
        if options.unpack {
            options.algorithm
        } else {
            Algorithm::Sha256
        },
    )?;
    let hash = if options.unpack {
        recursive
    } else {
        hash_file(&payload, options.algorithm)?
    };
    let ca = if options.unpack {
        CAHash::Nar(hash.clone())
    } else {
        CAHash::Flat(hash.clone())
    };
    let path: StorePath<String> = build_ca_path(&name, &ca, Vec::<String>::new(), false)?;
    publish(
        &payload,
        &path,
        &nar_hash,
        size,
        Vec::new(),
        &PathInfoDb::open()?,
    )?;
    println!("{}", nix_compat::nixbase32::encode(hash.digest_as_bytes()));
    if options.print_path {
        println!("{}", path.to_absolute_path());
    }
    Ok(())
}

fn prefetch_git(options: PrefetchGit) -> Result<()> {
    let algorithm: Algorithm = std::env::var("NIX_HASH_ALGO")
        .unwrap_or_else(|_| "sha256".into())
        .parse()?;
    let name = match options.name {
        Some(name) => name,
        None => git_name(&options.url, &options.rev)?,
    };
    validate_name(&name)?;
    let staging = Staging::new(Path::new(STORE_DIR))?;
    let payload = staging.payload();
    let rev = crate::fetchers::fetch_git_checkout(
        &options.url,
        &options.rev,
        payload.to_str().ok_or("non-UTF-8 staging path")?,
        options.fetch_submodules,
        options.fetch_lfs,
    )?;
    let (hash, nar_hash, size) = hash_nar(&payload, algorithm)?;
    let path: StorePath<String> = build_ca_path(
        &name,
        &CAHash::Nar(hash.clone()),
        Vec::<String>::new(),
        false,
    )?;
    publish(
        &payload,
        &path,
        &nar_hash,
        size,
        Vec::new(),
        &PathInfoDb::open()?,
    )?;
    println!(
        "{}",
        serde_json::json!({ "path": path.to_absolute_path(), "rev": rev, "hash": hash.to_sri_string() })
    );
    Ok(())
}

fn publish(
    source: &Path,
    path: &StorePath<String>,
    hash: &NixHash,
    size: u64,
    references: Vec<String>,
    db: &PathInfoDb,
) -> Result<()> {
    let absolute = path.to_absolute_path();
    let destination = Path::new(&absolute);
    match fs::symlink_metadata(destination) {
        Ok(_) => {
            // Never accept a cache hit merely because a path exists: aborted
            // downloads and manually modified paths are not valid store data.
            let (_, actual, actual_size) = hash_nar(destination, Algorithm::Sha256)?;
            if actual != *hash || actual_size != size {
                return Err(format!(
                    "existing store path has stale or corrupt content: {absolute}"
                )
                .into());
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => fs::rename(source, destination)?,
        Err(e) => return Err(e.into()),
    }
    crate::store::register_path(
        db,
        &absolute,
        &hash.to_nix_lowerhex_string(),
        size,
        references,
        Vec::new(),
    )?;
    Ok(())
}

fn instantiate(options: InstantiateArgs) -> Result<()> {
    let db = PathInfoDb::open()?;
    let (value, state) =
        crate::eval::evaluate_for_build(&format!("({}).drvPath", options.expr), &db)?;
    let target: String = serde_json::from_str(&value)?;
    let target = StorePath::<String>::from_absolute_path(target.as_bytes())?;
    for (path, drv) in state.known_paths.borrow().get_derivations() {
        let staging = Staging::new(Path::new(STORE_DIR))?;
        let payload = staging.payload();
        drv.serialize(&mut fs::File::create(&payload)?)?;
        let (_, hash, size) = hash_nar(&payload, Algorithm::Sha256)?;
        let references = drv
            .input_sources
            .iter()
            .chain(drv.input_derivations.keys())
            .map(StorePath::to_absolute_path)
            .collect();
        publish(&payload, path, &hash, size, references, &db)?;
    }
    println!("{}", target.to_absolute_path());
    Ok(())
}

fn load_derivation(
    path: &StorePath<String>,
    known: &mut KnownPaths,
    visiting: &mut BTreeSet<String>,
) -> Result<()> {
    if known.get_drv_by_drvpath(path).is_some() {
        return Ok(());
    }
    let absolute = path.to_absolute_path();
    if !visiting.insert(absolute.clone()) {
        return Err("cyclic input derivation graph".into());
    }
    let bytes = fs::read(&absolute)?;
    let drv = Derivation::from_aterm_bytes(&bytes)
        .map_err(|e| format!("invalid derivation {absolute}: {e:?}"))?;
    drv.validate(true)?;
    let name = path
        .name()
        .strip_suffix(".drv")
        .ok_or("expected a .drv store path")?;
    if drv.calculate_derivation_path(name)? != *path {
        return Err(format!("derivation contents do not match store path {absolute}").into());
    }
    for dependency in drv.input_derivations.keys() {
        load_derivation(dependency, known, visiting)?;
    }
    visiting.remove(&absolute);
    known.add_derivation(path.clone(), drv);
    Ok(())
}

fn realize_derivation(
    path: &StorePath<String>,
    known: &KnownPaths,
    db: &PathInfoDb,
    complete: &mut BTreeSet<String>,
) -> Result<()> {
    if complete.contains(&path.to_absolute_path()) {
        return Ok(());
    }
    let drv = known.get_drv_by_drvpath(path).ok_or("unknown derivation")?;
    for dependency in drv.input_derivations.keys() {
        realize_derivation(dependency, known, db, complete)?;
    }
    let result = crate::local_build::build_needed(path, known, db)?;
    // The generic builder does not check fixed-output hashes. Do so before
    // exposing compatibility outputs or allowing a parent derivation to run.
    for (name, output) in &drv.outputs {
        let Some(expected) = &output.ca_hash else {
            continue;
        };
        let output_path = result
            .outputs
            .get(name)
            .ok_or("missing derivation output")?;
        let algorithm: Algorithm = expected.hash().algo().to_string().parse()?;
        let actual = match expected {
            CAHash::Flat(_) => hash_file(Path::new(output_path), algorithm)?,
            CAHash::Nar(_) => hash_nar(Path::new(output_path), algorithm)?.0,
            CAHash::Text(_) => {
                return Err("text-addressed derivation outputs are unsupported".into())
            }
        };
        if actual != *expected.hash() {
            let meta = fs::symlink_metadata(output_path)?;
            if meta.is_dir() {
                fs::remove_dir_all(output_path)?;
            } else {
                fs::remove_file(output_path)?;
            }
            db.delete(output_path)?;
            return Err(format!(
                "hash mismatch in fixed-output derivation {}:\n  specified: {}\n  got:       {}",
                path.to_absolute_path(),
                expected.hash().to_sri_string(),
                actual.to_sri_string()
            )
            .into());
        }
    }
    complete.insert(path.to_absolute_path());
    Ok(())
}

fn store(options: StoreArgs) -> Result<()> {
    if options.indirect != options.add_root.is_some() {
        return Err("--indirect and --add-root must be used together".into());
    }
    let path = StorePath::<String>::from_absolute_path(options.realize.as_bytes())?;
    let db = PathInfoDb::open()?;
    let outputs = if path.name().ends_with(".drv") {
        let mut known = KnownPaths::default();
        load_derivation(&path, &mut known, &mut BTreeSet::new())?;
        realize_derivation(&path, &known, &db, &mut BTreeSet::new())?;
        known
            .get_drv_by_drvpath(&path)
            .ok_or("unknown derivation")?
            .outputs
            .values()
            .map(|output| {
                output
                    .path
                    .as_ref()
                    .map(StorePath::to_absolute_path)
                    .ok_or_else(|| "missing output path".into())
            })
            .collect::<Result<Vec<_>>>()?
    } else {
        let info = db
            .get(&options.realize)?
            .ok_or("store path is not registered; fetch it before realizing")?;
        let (_, actual, size) = hash_nar(Path::new(&options.realize), Algorithm::Sha256)?;
        let expected = NixHash::from_str(&info.nar_hash, Some(HashAlgo::Sha256))?;
        if expected != actual || info.nar_size != size {
            return Err("registered store path has corrupt content".into());
        }
        vec![options.realize]
    };
    if let Some(root) = options.add_root {
        if outputs.len() != 1 {
            return Err("--add-root requires exactly one realized output".into());
        }
        crate::store::GcRoots::open()?.add_indirect_root(&root, &outputs[0])?;
    }
    for output in outputs {
        println!("{output}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn nar_executable_marker_uses_only_owner_execute_permission() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("file");
        let content = b"permission invariant\n";
        fs::write(&path, content).unwrap();
        for (mode, executable) in [
            (0o644, false),
            (0o654, false),
            (0o645, false),
            (0o744, true),
            (0o755, true),
        ] {
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
            // Construct the expected NAR directly with the upstream writer,
            // independent of Snix's filesystem traversal and permission test.
            let mut expected_nar = Vec::new();
            nix_compat::nar::writer::open(&mut expected_nar)
                .unwrap()
                .file(
                    executable,
                    content.len() as u64,
                    &mut io::Cursor::new(content.as_slice()),
                )
                .unwrap();
            let (selected, metadata_hash, size) = hash_nar(&path, Algorithm::Sha512).unwrap();
            assert_eq!(
                selected,
                NixHash::Sha512(Box::new(Sha512::digest(&expected_nar).into())),
                "mode {mode:o}"
            );
            assert_eq!(
                metadata_hash,
                NixHash::Sha256(Sha256::digest(&expected_nar).into()),
                "mode {mode:o}"
            );
            assert_eq!(size, expected_nar.len() as u64);
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn nar_hashing_rejects_socket_nodes_instead_of_hashing_a_partial_archive() {
        use std::os::unix::net::UnixListener;
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("socket");
        let _listener = UnixListener::bind(&socket).unwrap();
        let error = crate::local_build::nar_hash_path(&socket).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        let nested_error = hash_nar(temp.path(), Algorithm::Sha512).unwrap_err();
        assert_eq!(
            nested_error.downcast_ref::<io::Error>().unwrap().kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn git_names_match_prefetch_script_revision_rules() {
        assert_eq!(
            git_name("https://example.org/org/project.git", "refs/tags/v1").unwrap(),
            "project"
        );
        assert_eq!(
            git_name("https://example.org/org/project.git", "0123456789abcdef").unwrap(),
            "project-0123456"
        );
        assert_eq!(
            git_name("git@example.org:project.git", "main").unwrap(),
            "project-main"
        );
    }
}
