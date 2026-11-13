//! Nix expression evaluation using upstream snix-eval + snix-glue.
//!
//! Sets up a tokio runtime, constructs in-memory store services, and
//! uses upstream SnixStoreIO with derivation/fetcher/import builtins.

use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, BufRead, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use snix_eval::{EvalIO, Evaluation};

use snix_build::buildservice::DummyBuildService;
use snix_castore::{blobservice::BlobService, directoryservice::DirectoryService, Node};
use snix_glue::builtins::{add_derivation_builtins, add_fetcher_builtins, add_import_builtins};
use snix_glue::known_paths::KnownPaths;
use snix_glue::snix_store_io::SnixStoreIO;
use snix_store::pathinfoservice::PathInfoService;
use snix_store::utils::{construct_services, ServiceUrlsMemory};

use crate::pathinfo::{PathInfo, PathInfoDb};

/// Load CLI input while retaining the file location for relative Nix paths.
pub(crate) fn read_source(
    expr: Option<String>,
    file: Option<String>,
) -> Result<(String, Option<PathBuf>), Box<dyn std::error::Error>> {
    match (expr, file) {
        (Some(expr), _) => Ok((expr, None)),
        (_, Some(file)) => {
            let path = PathBuf::from(file);
            Ok((fs::read_to_string(&path)?, Some(path)))
        }
        _ => Err("provide --expr or --file".into()),
    }
}

/// Evaluate a Nix expression from --expr or --file
pub fn run(
    expr: Option<String>,
    file: Option<String>,
    raw: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let (source, location) = read_source(expr, file)?;
    let (result, _io) = evaluate_source(&source, location, None)?;
    if raw {
        let s = result.to_string();
        if s.starts_with('"') && s.ends_with('"') && s.len() >= 2 {
            let inner = &s[1..s.len() - 1];
            let unescaped = inner
                .replace("\\\"", "\"")
                .replace("\\\\", "\\")
                .replace("\\n", "\n")
                .replace("\\t", "\t");
            print!("{unescaped}");
        } else {
            print!("{s}");
        }
    } else {
        println!("{result}");
    }
    Ok(())
}

/// Show a .drv file in human-readable JSON
pub fn show_derivation(path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let bytes = std::fs::read(path)?;
    let trimmed = bytes.as_slice();

    match nix_compat::derivation::Derivation::from_aterm_bytes(trimmed) {
        Ok(drv) => {
            let json = serde_json::json!({
                "args": drv.arguments,
                "builder": drv.builder,
                "env": drv.environment.into_iter()
                    .map(|(k, v)| (k, v.to_string()))
                    .collect::<std::collections::BTreeMap<String, String>>(),
                "inputDrvs": drv.input_derivations,
                "inputSrcs": drv.input_sources,
                "outputs": drv.outputs,
                "system": drv.system,
            });
            println!("{}", serde_json::to_string_pretty(&json)?);
        }
        Err(e) => return Err(format!("parse error: {e:#?}").into()),
    }

    Ok(())
}

/// Interactive REPL
pub fn repl() -> Result<(), Box<dyn std::error::Error>> {
    println!("snix repl (Redox OS)");
    println!("Type Nix expressions. Ctrl-D to exit.\n");

    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = line?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        match evaluate(line) {
            Ok(val) => println!("{val}"),
            Err(e) => eprintln!("error: {e}"),
        }

        print!("nix> ");
        stdout.flush()?;
    }

    Ok(())
}

/// Core evaluation function
fn evaluate(expr: &str) -> Result<String, Box<dyn std::error::Error>> {
    let (result, _io) = evaluate_with_state(expr)?;
    Ok(result)
}

/// Evaluate a Nix expression, returning both the string result and the
/// shared SnixStoreIO (which contains KnownPaths with all registered
/// derivations).
///
/// Uses upstream SnixStoreIO with in-memory store services for
/// derivation path calculation, fetcher builtins, and import builtins.
/// A tokio runtime is created for the async store operations.
pub fn evaluate_with_state(
    expr: &str,
) -> Result<(String, Rc<SnixStoreIO>), Box<dyn std::error::Error>> {
    evaluate_source(expr, None, None)
}

/// Evaluate a build graph and publish its imported sources before executing builders.
/// Plain evaluation and dry runs keep their in-memory-only store behavior.
pub fn evaluate_for_build(
    expr: &str,
    db: &PathInfoDb,
) -> Result<(String, Rc<SnixStoreIO>), Box<dyn std::error::Error>> {
    evaluate_source(expr, None, Some(db))
}

/// Evaluate CLI source at its original location, optionally publishing build inputs.
pub(crate) fn evaluate_source(
    expr: &str,
    location: Option<PathBuf>,
    db: Option<&PathInfoDb>,
) -> Result<(String, Rc<SnixStoreIO>), Box<dyn std::error::Error>> {
    evaluate_with_state_impl(
        expr,
        location,
        db.map(|db| (db, Path::new(nix_compat::store_path::STORE_DIR))),
    )
}

fn evaluate_with_state_impl(
    expr: &str,
    location: Option<PathBuf>,
    store: Option<(&PathInfoDb, &Path)>,
) -> Result<(String, Rc<SnixStoreIO>), Box<dyn std::error::Error>> {
    // Install ring as the default rustls crypto provider. Required because
    // we use reqwest with rustls-no-provider (to avoid aws-lc-rs which
    // doesn't compile on Redox). This is idempotent — repeated calls are fine.
    let _ = rustls::crypto::ring::default_provider().install_default();

    // Ensure TLS root certificates are discoverable. rustls-native-certs
    // checks SSL_CERT_FILE before platform probing. On Redox, the platform
    // verifier doesn't know about the OS, so we point it at our bundle.
    if std::env::var_os("SSL_CERT_FILE").is_none() {
        let cert_path = "/etc/ssl/certs/ca-certificates.crt";
        if std::path::Path::new(cert_path).exists() {
            std::env::set_var("SSL_CERT_FILE", cert_path);
        }
    }

    let runtime = tokio::runtime::Runtime::new().map_err(|e| format!("tokio runtime: {e}"))?;

    let (blob_service, directory_service, path_info_service, nar_calculation_service) = runtime
        .block_on(async {
            construct_services(<ServiceUrlsMemory as clap::Parser>::parse_from(
                std::iter::empty::<&str>(),
            ))
            .await
        })
        .map_err(|e| format!("store services: {e}"))?;

    let io = Rc::new(SnixStoreIO::new(
        Arc::clone(&blob_service),
        Arc::clone(&directory_service),
        Arc::clone(&path_info_service),
        nar_calculation_service.into(),
        Arc::<DummyBuildService>::default(),
        runtime.handle().clone(),
        Vec::new(),
    ));

    let mut eval_builder = Evaluation::builder(io.clone() as Rc<dyn EvalIO>)
        .enable_import()
        .add_builtins(snix_eval::builtins::impure_builtins());
    eval_builder = add_derivation_builtins(eval_builder, Rc::clone(&io));
    eval_builder = add_fetcher_builtins(eval_builder, Rc::clone(&io));
    eval_builder = add_import_builtins(eval_builder, Rc::clone(&io));

    // Override upstream's NotImplemented fetchGit with our git-CLI-based impl.
    // add_builtins appends to a Vec that becomes a FxHashMap, so later entries
    // with the same key win.
    eval_builder = eval_builder.add_builtins(make_fetchgit_builtin(Rc::clone(&io)));

    let eval = eval_builder.build();

    let result = eval.evaluate(expr, location);

    if !result.errors.is_empty() {
        let errors: Vec<String> = result
            .errors
            .iter()
            .map(|error| {
                // Generated expressions can embed entire manifests. Keep the root
                // diagnostic and source span without repeatedly dumping trace frames.
                let mut cause = error;
                while let snix_eval::ErrorKind::NativeError { err, .. }
                | snix_eval::ErrorKind::BytecodeError(err) = &cause.kind
                {
                    cause = err;
                }
                cause.fancy_format_str()
            })
            .collect();
        return Err(errors.join("\n").into());
    }
    if result.value.is_some() {
        if let Some((db, store_root)) = store {
            runtime.block_on(materialize_input_sources(
                &io.known_paths.borrow(),
                blob_service.as_ref(),
                directory_service.as_ref(),
                path_info_service.as_ref(),
                db,
                store_root,
            ))?;
        }
    }

    match result.value {
        Some(v) => Ok((format!("{v}"), io)),
        None => Err("no value produced".into()),
    }
}

async fn materialize_input_sources(
    known_paths: &KnownPaths,
    blobs: &dyn BlobService,
    directories: &dyn DirectoryService,
    path_infos: &dyn PathInfoService,
    db: &PathInfoDb,
    store_root: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static IMPORT_COUNTER: AtomicU64 = AtomicU64::new(0);

    let sources: BTreeSet<_> = known_paths
        .get_derivations()
        .flat_map(|(_, drv)| drv.input_sources.iter())
        .collect();
    for source in sources {
        let store_path = source.to_absolute_path();
        let destination = store_root.join(source.to_string());
        let present = match fs::symlink_metadata(&destination) {
            Ok(_) => true,
            Err(e) if e.kind() == io::ErrorKind::NotFound => false,
            Err(e) => return Err(e.into()),
        };
        if present && db.is_registered(&store_path) {
            continue;
        }
        let info = path_infos
            .get(*source.digest())
            .await
            .map_err(io::Error::other)?;
        let Some(info) = info else {
            if present {
                // Existing store inputs need not have been imported by this evaluation.
                continue;
            }
            return Err(format!("source input is unavailable: {store_path}").into());
        };
        let metadata = PathInfo::from_upstream(&info);
        if !present {
            fs::create_dir_all(store_root)?;
            let id = IMPORT_COUNTER.fetch_add(1, Ordering::Relaxed);
            let staging = store_root.join(format!(".snix-import-{}-{id}", std::process::id()));
            fs::DirBuilder::new().mode(0o700).create(&staging)?;
            let staged_source = staging.join("source");
            let result = async {
                write_source_node(info.node, &staged_source, blobs, directories).await?;
                if let Err(e) = fs::rename(&staged_source, &destination) {
                    // Another importer may have finished the same immutable store object.
                    if fs::symlink_metadata(&destination).is_err() {
                        return Err(e);
                    }
                }
                Ok::<_, io::Error>(())
            }
            .await;
            let cleanup = fs::remove_dir_all(&staging);
            result?;
            cleanup?;
        }
        db.register(&metadata)?;
    }
    Ok(())
}

async fn write_source_node(
    node: Node,
    destination: &Path,
    blobs: &dyn BlobService,
    directories: &dyn DirectoryService,
) -> io::Result<()> {
    use tokio::io::AsyncWriteExt;

    let mut pending = vec![(destination.to_path_buf(), node)];
    while let Some((path, node)) = pending.pop() {
        match node {
            Node::Directory { digest, .. } => {
                let directory = directories
                    .get(&digest)
                    .await
                    .map_err(io::Error::other)?
                    .ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::NotFound,
                            format!("missing source directory {digest}"),
                        )
                    })?;
                fs::create_dir(&path)?;
                for (name, child) in directory.into_nodes() {
                    pending.push((path.join(OsStr::from_bytes(name.as_ref())), child));
                }
            }
            Node::File {
                digest,
                size,
                executable,
            } => {
                let mut reader = blobs.open_read(&digest).await?.ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::NotFound,
                        format!("missing source blob {digest}"),
                    )
                })?;
                let mut file = tokio::fs::File::create(&path).await?;
                let written = tokio::io::copy(&mut reader, &mut file).await?;
                file.flush().await?;
                if written != size {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("source blob {digest}: expected {size} bytes, received {written}"),
                    ));
                }
                file.set_permissions(fs::Permissions::from_mode(if executable {
                    0o555
                } else {
                    0o444
                }))
                .await?;
            }
            Node::Symlink { target } => {
                std::os::unix::fs::symlink(OsStr::from_bytes(target.as_ref()), &path)?;
            }
        }
    }
    Ok(())
}

/// Fetch Git into a private staging directory, then publish its real NAR-based
/// address. A custom store root keeps the filesystem contract testable without
/// touching the host's global store; the logical address remains /nix/store.
fn fetch_git_source(
    url: &str,
    revision: &str,
    name: &str,
    expected_sri: Option<&str>,
    submodules: bool,
    lfs: bool,
    db: &PathInfoDb,
    store_root: &Path,
) -> Result<nix_compat::store_path::StorePath<String>, Box<dyn std::error::Error>> {
    use nix_compat::nixhash::{CAHash, HashAlgo, NixHash};
    use nix_compat::store_path::{build_ca_path, validate_name, StorePath};
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);

    validate_name(name)?;
    let expected = expected_sri
        .map(|value| NixHash::from_str(value, Some(HashAlgo::Sha256)))
        .transpose()?;
    // A known content hash permits an offline cache hit, but never trust an
    // existing path without checking its contents and registering its metadata.
    if let Some(expected) = &expected {
        let path: StorePath<String> = build_ca_path(
            name,
            &CAHash::Nar(expected.clone()),
            std::iter::empty::<&str>(),
            false,
        )?;
        let destination = store_root.join(path.to_string());
        match fs::symlink_metadata(&destination) {
            Ok(_) => {
                let (hash, size) = crate::local_build::nar_hash_path(&destination)?;
                if NixHash::from_str(&hash, Some(HashAlgo::Sha256))? != *expected {
                    return Err(format!(
                        "fetchGit: cached path has corrupt content: {}",
                        path.to_absolute_path()
                    )
                    .into());
                }
                crate::store::register_path(
                    db,
                    &path.to_absolute_path(),
                    &hash,
                    size,
                    Vec::new(),
                    Vec::new(),
                )?;
                return Ok(path);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.into()),
        }
    }

    fs::create_dir_all(store_root)?;
    let staging = loop {
        let path = store_root.join(format!(
            ".snix-fetchgit-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        match fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => break path,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    };
    let result: Result<StorePath<String>, Box<dyn std::error::Error>> = (|| {
        let source = staging.join("source");
        crate::fetchers::fetch_git_checkout(
            url,
            revision,
            source.to_str().ok_or("non-UTF-8 Git staging path")?,
            submodules,
            lfs,
        )?;
        let (hash, size) = crate::local_build::nar_hash_path(&source)?;
        let actual = NixHash::from_str(&hash, Some(HashAlgo::Sha256))?;
        if let Some(expected) = &expected {
            if expected != &actual {
                return Err(format!(
                    "fetchGit: NAR hash mismatch:\n  expected: {}\n  got:      {}",
                    expected, actual
                )
                .into());
            }
        }
        let path: StorePath<String> = build_ca_path(
            name,
            &CAHash::Nar(actual),
            std::iter::empty::<&str>(),
            false,
        )?;
        let destination = store_root.join(path.to_string());
        let verify_existing = || -> Result<(), Box<dyn std::error::Error>> {
            let (existing_hash, existing_size) = crate::local_build::nar_hash_path(&destination)?;
            if existing_hash != hash || existing_size != size {
                return Err(format!(
                    "fetchGit: existing store path has stale or corrupt content: {}",
                    path.to_absolute_path()
                )
                .into());
            }
            Ok(())
        };
        match fs::symlink_metadata(&destination) {
            Ok(_) => verify_existing()?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if let Err(error) = fs::rename(&source, &destination) {
                    // A concurrent fetch may have published the same object.
                    if fs::symlink_metadata(&destination).is_err() {
                        return Err(error.into());
                    }
                    verify_existing()?;
                }
            }
            Err(error) => return Err(error.into()),
        }
        crate::store::register_path(
            db,
            &path.to_absolute_path(),
            &hash,
            size,
            Vec::new(),
            Vec::new(),
        )?;
        Ok(path)
    })();
    let cleanup = fs::remove_dir_all(staging);
    let path = result?;
    cleanup?;
    Ok(path)
}

/// Build a `fetchGit` builtin that uses our git CLI-based fetch.
///
/// Accepts `{ url, rev?, ref?, narHash?, name?, submodules?, lfs? }` or a URL string.
/// Returns a store path string with Nix context.
fn make_fetchgit_builtin(io: Rc<SnixStoreIO>) -> Vec<(&'static str, snix_eval::Value)> {
    use snix_eval::generators::Gen;
    use snix_eval::{Builtin, ErrorKind, NixContext, NixContextElement, NixString, Value};

    let builtin = Builtin::new("fetchGit", None, 1, move |args| {
        let _io = io.clone();
        Gen::new(|co| {
            let fut: std::pin::Pin<
                Box<dyn std::future::Future<Output = Result<Value, ErrorKind>>>,
            > = Box::pin(async move {
                let arg =
                    snix_eval::generators::request_force(&co, args.into_iter().next().unwrap())
                        .await;
                if arg.is_catchable() {
                    return Ok(arg);
                }

                // Force attribute values as upstream builtins do: generated
                // loaders pass projections and expressions, not just literals.
                let (url, rev, ref_, nar_hash, name, submodules, lfs) = if let Ok(s) = arg.to_str()
                {
                    (
                        String::from_utf8(s.as_bytes().to_vec()).map_err(|_| ErrorKind::Utf8)?,
                        None,
                        None,
                        None,
                        "source".to_owned(),
                        false,
                        false,
                    )
                } else {
                    let attrs = arg.to_attrs()?;
                    let mut strings: [Option<String>; 5] = Default::default();
                    for (slot, key) in strings
                        .iter_mut()
                        .zip(["url", "rev", "ref", "narHash", "name"])
                    {
                        if let Some(value) = attrs.select(key) {
                            let value =
                                snix_eval::generators::request_force(&co, value.clone()).await;
                            if value.is_catchable() {
                                return Ok(value);
                            }
                            let value = value.to_str()?;
                            *slot = Some(
                                String::from_utf8(value.as_bytes().to_vec())
                                    .map_err(|_| ErrorKind::Utf8)?,
                            );
                        }
                    }
                    let mut flags = [false; 2];
                    for (slot, key) in flags.iter_mut().zip(["submodules", "lfs"]) {
                        if let Some(value) = attrs.select(key) {
                            let value =
                                snix_eval::generators::request_force(&co, value.clone()).await;
                            if value.is_catchable() {
                                return Ok(value);
                            }
                            *slot = value.as_bool()?;
                        }
                    }
                    let [url, rev, ref_, nar_hash, name] = strings;
                    (
                        url.ok_or_else(|| ErrorKind::AttributeNotFound { name: "url".into() })?,
                        rev,
                        ref_,
                        nar_hash,
                        name.unwrap_or_else(|| "source".to_owned()),
                        flags[0],
                        flags[1],
                    )
                };
                // A supplied revision always wins over a moving ref. Let git
                // resolve refs (including annotated tags) to the checked-out
                // commit, rather than guessing from ls-remote's first result.
                let revision = rev.as_deref().or(ref_.as_deref()).unwrap_or("HEAD");

                let db =
                    PathInfoDb::open().map_err(|error| ErrorKind::SnixError(Arc::new(error)))?;
                let store_path = fetch_git_source(
                    &url,
                    revision,
                    &name,
                    nar_hash.as_deref(),
                    submodules,
                    lfs,
                    &db,
                    Path::new(nix_compat::store_path::STORE_DIR),
                )
                .map_err(|error| {
                    ErrorKind::SnixError(Arc::new(io::Error::other(format!("fetchGit: {error}"))))
                })?
                .to_absolute_path();

                // Return store path with context
                let context =
                    NixContext::new().append(NixContextElement::Plain(store_path.clone()));
                Ok(Value::String(NixString::new_context_from(
                    context, store_path,
                )))
            });
            fut
        })
    });

    vec![("fetchGit", Value::Builtin(builtin))]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git_fixture(tmp: &Path) -> (PathBuf, String) {
        let repo = tmp.join("repo");
        fs::create_dir(&repo).unwrap();
        let git = |arguments: &[&str]| {
            let output = std::process::Command::new("git")
                .current_dir(&repo)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_AUTHOR_NAME", "Snix test")
                .env("GIT_AUTHOR_EMAIL", "snix@example.invalid")
                .env("GIT_COMMITTER_NAME", "Snix test")
                .env("GIT_COMMITTER_EMAIL", "snix@example.invalid")
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {} failed: {}",
                arguments[0],
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_owned()
        };
        git(&["init"]);
        fs::write(repo.join("value"), "pinned content\n").unwrap();
        git(&["add", "value"]);
        git(&["commit", "-m", "pinned"]);
        let pinned = git(&["rev-parse", "HEAD"]);
        git(&["tag", "-a", "-m", "annotated pinned tag", "pinned"]);
        fs::write(repo.join("value"), "newer content\n").unwrap();
        git(&["commit", "-am", "newer"]);
        (repo, pinned)
    }

    #[test]
    fn git_source_without_nar_hash_is_canonical_registered_and_pinned() {
        use nix_compat::nixhash::{CAHash, HashAlgo, NixHash};
        use nix_compat::store_path::{build_ca_path, StorePath};
        let tmp = tempfile::tempdir().unwrap();
        let (repo, pinned) = git_fixture(tmp.path());
        let expected_tree = tmp.path().join("expected");
        fs::create_dir(&expected_tree).unwrap();
        fs::write(expected_tree.join("value"), "pinned content\n").unwrap();
        let (hash, size) = crate::local_build::nar_hash_path(&expected_tree).unwrap();
        let expected_hash = NixHash::from_str(&hash, Some(HashAlgo::Sha256)).unwrap();
        let expected_path: StorePath<String> = build_ca_path(
            "fixture",
            &CAHash::Nar(expected_hash.clone()),
            std::iter::empty::<&str>(),
            false,
        )
        .unwrap();
        let store = tmp.path().join("store");
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();
        let url = format!("file://{}", repo.display());
        let path =
            fetch_git_source(&url, &pinned, "fixture", None, false, false, &db, &store).unwrap();
        assert_eq!(path, expected_path);
        let destination = store.join(path.to_string());
        assert_eq!(
            fs::read_to_string(destination.join("value")).unwrap(),
            "pinned content\n"
        );
        assert!(!destination.join(".git").exists());
        let metadata = db.get(&path.to_absolute_path()).unwrap().unwrap();
        assert_eq!(metadata.nar_hash, hash);
        assert_eq!(metadata.nar_size, size);
        // Different origins and annotated refs to identical content converge
        // on the same address used by nix-prefetch-git's SHA256 NAR path.
        let tagged = fetch_git_source(
            repo.to_str().unwrap(),
            "refs/tags/pinned",
            "fixture",
            None,
            false,
            false,
            &db,
            &store,
        )
        .unwrap();
        assert_eq!(tagged, path);
        assert_eq!(fs::read_dir(&store).unwrap().count(), 1);
        // A verified hash permits offline evaluation without contacting Git.
        assert_eq!(
            fetch_git_source(
                "file:///nonexistent-snix-test-repo",
                &pinned,
                "fixture",
                Some(&expected_hash.to_sri_string()),
                false,
                false,
                &db,
                &store
            )
            .unwrap(),
            path
        );
        let roots = crate::store::GcRoots::open_at(tmp.path().join("roots")).unwrap();
        roots
            .add_indirect_root(&tmp.path().join("generation"), &path.to_absolute_path())
            .unwrap();
        assert!(roots
            .compute_live_set(&db)
            .unwrap()
            .contains(&path.to_absolute_path()));
        fs::write(destination.join("value"), "corrupt").unwrap();
        assert!(fetch_git_source(
            "file:///nonexistent-snix-test-repo",
            &pinned,
            "fixture",
            Some(&expected_hash.to_sri_string()),
            false,
            false,
            &db,
            &store
        )
        .is_err());
    }

    #[test]
    fn git_source_hash_mismatch_and_failed_revision_leave_no_partial_store_data() {
        use nix_compat::nixhash::NixHash;
        let tmp = tempfile::tempdir().unwrap();
        let (repo, pinned) = git_fixture(tmp.path());
        let store = tmp.path().join("store");
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();
        let url = format!("file://{}", repo.display());
        let wrong_hash = NixHash::Sha256([0; 32]).to_sri_string();
        fetch_git_source(
            &url,
            &pinned,
            "fixture",
            Some(&wrong_hash),
            false,
            false,
            &db,
            &store,
        )
        .unwrap_err();
        assert_eq!(fs::read_dir(&store).unwrap().count(), 0);
        assert!(db.all_paths_set().unwrap().is_empty());
        assert!(fetch_git_source(
            &url,
            "refs/tags/missing",
            "fixture",
            None,
            false,
            false,
            &db,
            &store
        )
        .is_err());
        assert_eq!(fs::read_dir(&store).unwrap().count(), 0);
        assert!(db.all_paths_set().unwrap().is_empty());
    }

    #[test]
    fn file_source_resolves_parent_reads_and_nested_imports() {
        let tmp = tempfile::tempdir().unwrap();
        let nested = tmp.path().join("nested");
        fs::create_dir(&nested).unwrap();
        fs::write(tmp.path().join("manifest.json"), "file-context").unwrap();
        fs::write(nested.join("value.nix"), "builtins.readFile ../manifest.json").unwrap();
        let file = nested.join("default.nix");
        fs::write(&file, "import ./value.nix").unwrap();
        let (source, location) = read_source(None, Some(file.to_str().unwrap().into())).unwrap();
        assert_eq!(location.as_deref(), Some(file.as_path()));
        assert_eq!(evaluate_source(&source, location, None).unwrap().0, "\"file-context\"");
    }

    #[test]
    fn file_source_build_graph_uses_original_location() {
        let tmp = tempfile::tempdir().unwrap();
        let nested = tmp.path().join("nested");
        fs::create_dir(&nested).unwrap();
        fs::write(tmp.path().join("manifest.json"), "build-context").unwrap();
        let file = nested.join("build.nix");
        fs::write(&file, r#"derivation { name = "file-context"; system = "x86_64-linux"; builder = "/bin/sh"; bootstrapInputs = builtins.readFile ../manifest.json; }"#).unwrap();
        let (source, location) = read_source(None, Some(file.to_str().unwrap().into())).unwrap();
        let (_, state) = evaluate_source(&format!("({source}).drvPath"), location, None).unwrap();
        let known = state.known_paths.borrow();
        let (_, drv) = known.get_derivations().next().unwrap();
        assert_eq!(drv.environment.get("bootstrapInputs").unwrap(), "build-context");
    }

    #[test]
    fn file_source_rejects_missing_sibling_and_keeps_expr_precedence() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("default.nix");
        fs::write(&file, "builtins.readFile ./missing-manifest.json").unwrap();
        let (source, location) = read_source(None, Some(file.to_str().unwrap().into())).unwrap();
        assert!(evaluate_source(&source, location, None).is_err());
        let (source, location) = read_source(Some("42".into()), Some("missing.nix".into())).unwrap();
        assert!(location.is_none());
        assert_eq!(evaluate_source(&source, location, None).unwrap().0, "42");
        assert!(read_source(None, Some("missing.nix".into())).is_err());
    }

    #[test]
    fn manifest_json_can_be_read_and_decoded() {
        let tmp = tempfile::tempdir().unwrap();
        let manifest = tmp.path().join("manifest.json");
        fs::write(&manifest, r#"{"generation":{"id":7}}"#).unwrap();
        let expression = format!(
            "let m = builtins.fromJSON (builtins.readFile {}); in builtins.toString m.generation.id",
            manifest.display(),
        );
        assert_eq!(evaluate(&expression).unwrap(), "\"7\"");
    }

    #[test]
    fn build_inputs_survive_original_removal_with_contents_modes_and_symlinks() {
        let tmp = tempfile::tempdir().unwrap();
        let original = tmp.path().join("source-tree");
        fs::create_dir_all(original.join("nested")).unwrap();
        fs::write(original.join("nested/data"), b"\x00\xffsource\n").unwrap();
        fs::write(original.join("build.sh"), "#!/bin/sh\necho native\n").unwrap();
        fs::set_permissions(original.join("build.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink("nested/data", original.join("data-link")).unwrap();
        let file_input = tmp.path().join("single-source");
        fs::write(&file_input, b"standalone\x00input").unwrap();
        let expression = format!(
            "let child = derivation {{ name = \"source-child\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; source = {}; }}; in (derivation {{ name = \"source-root\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; inherit child; source = {}; generated = builtins.toFile \"builder-config\" \"generated source\\n\"; }}).drvPath",
            original.display(), file_input.display(),
        );
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();
        let store = tmp.path().join("store");
        let (_, state) = evaluate_with_state_impl(&expression, None, Some((&db, &store))).unwrap();
        fs::remove_dir_all(&original).unwrap();
        fs::remove_file(&file_input).unwrap();

        let known = state.known_paths.borrow();
        let sources: BTreeSet<_> = known
            .get_derivations()
            .flat_map(|(_, drv)| drv.input_sources.iter())
            .collect();
        assert_eq!(
            sources.len(),
            3,
            "literal and generated dependency sources must be published"
        );
        let mut file_contents = BTreeSet::new();
        for source in sources {
            let path = store.join(source.to_string());
            if path.is_dir() {
                assert_eq!(
                    fs::read(path.join("nested/data")).unwrap(),
                    b"\x00\xffsource\n"
                );
                assert_eq!(
                    fs::read(path.join("build.sh")).unwrap(),
                    b"#!/bin/sh\necho native\n"
                );
                assert_eq!(
                    fs::metadata(path.join("build.sh"))
                        .unwrap()
                        .permissions()
                        .mode()
                        & 0o777,
                    0o555
                );
                assert_eq!(
                    fs::metadata(path.join("nested/data"))
                        .unwrap()
                        .permissions()
                        .mode()
                        & 0o777,
                    0o444
                );
                assert_eq!(
                    fs::read_link(path.join("data-link")).unwrap(),
                    Path::new("nested/data")
                );
                assert_eq!(
                    fs::read(path.join("data-link")).unwrap(),
                    b"\x00\xffsource\n"
                );
            } else {
                file_contents.insert(fs::read(&path).unwrap());
                assert_eq!(
                    fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                    0o444
                );
            }
            let metadata = db.get(&source.to_absolute_path()).unwrap().unwrap();
            let (hash, size) = crate::local_build::nar_hash_path(&path).unwrap();
            assert_eq!(metadata.nar_hash, hash);
            assert_eq!(metadata.nar_size, size);
        }
        assert_eq!(
            file_contents,
            BTreeSet::from([
                b"standalone\x00input".to_vec(),
                b"generated source\n".to_vec(),
            ])
        );
    }

    // ===== Arithmetic =====

    #[test]
    fn test_arithmetic_addition() {
        let result = evaluate("1 + 1").unwrap();
        assert_eq!(result, "2");
    }

    #[test]
    fn test_arithmetic_subtraction() {
        let result = evaluate("10 - 3").unwrap();
        assert_eq!(result, "7");
    }

    #[test]
    fn test_arithmetic_multiplication() {
        let result = evaluate("6 * 7").unwrap();
        assert_eq!(result, "42");
    }

    #[test]
    fn test_arithmetic_division() {
        let result = evaluate("10 / 3").unwrap();
        assert_eq!(result, "3");
    }

    // ===== Strings =====

    #[test]
    fn test_string_literal() {
        let result = evaluate("\"hello\"").unwrap();
        assert_eq!(result, "\"hello\"");
    }

    #[test]
    fn test_string_concatenation() {
        let result = evaluate("\"hello\" + \" world\"").unwrap();
        assert_eq!(result, "\"hello world\"");
    }

    // ===== Booleans =====

    #[test]
    fn test_boolean_true() {
        let result = evaluate("true").unwrap();
        assert_eq!(result, "true");
    }

    #[test]
    fn test_boolean_false() {
        let result = evaluate("false").unwrap();
        assert_eq!(result, "false");
    }

    #[test]
    fn test_boolean_negation() {
        let result = evaluate("!true").unwrap();
        assert_eq!(result, "false");
    }

    #[test]
    fn test_boolean_and() {
        let result = evaluate("true && false").unwrap();
        assert_eq!(result, "false");
    }

    #[test]
    fn test_boolean_or() {
        let result = evaluate("true || false").unwrap();
        assert_eq!(result, "true");
    }

    // ===== Lists =====

    #[test]
    fn test_list_simple() {
        let result = evaluate("[1 2 3]").unwrap();
        assert!(result.contains("1"));
        assert!(result.contains("2"));
        assert!(result.contains("3"));
    }

    // ===== Attribute Sets =====

    #[test]
    fn test_attrset_access() {
        let result = evaluate("{ a = 1; }.a").unwrap();
        assert_eq!(result, "1");
    }

    #[test]
    fn test_attrset_nested_access() {
        let result = evaluate("{ a = { b = 2; }; }.a.b").unwrap();
        assert_eq!(result, "2");
    }

    // ===== Let Expressions =====

    #[test]
    fn test_let_expression() {
        let result = evaluate("let x = 5; in x * 2").unwrap();
        assert_eq!(result, "10");
    }

    // ===== Builtins =====

    #[test]
    fn test_builtin_length() {
        let result = evaluate("builtins.length [1 2 3]").unwrap();
        assert_eq!(result, "3");
    }

    #[test]
    fn test_builtin_head() {
        let result = evaluate("builtins.head [42 99]").unwrap();
        assert_eq!(result, "42");
    }

    #[test]
    fn test_builtin_typeof() {
        let result = evaluate("builtins.typeOf 1").unwrap();
        assert_eq!(result, "\"int\"");
    }

    #[test]
    fn test_builtin_attrnames() {
        let result = evaluate("builtins.attrNames { b = 1; a = 2; }").unwrap();
        assert!(result.contains("a"));
        assert!(result.contains("b"));
    }

    // ===== Functions =====

    #[test]
    fn test_function_simple() {
        let result = evaluate("(x: x + 1) 5").unwrap();
        assert_eq!(result, "6");
    }

    #[test]
    fn test_function_pattern_matching() {
        let result = evaluate("let f = {a, b}: a + b; in f { a = 3; b = 4; }").unwrap();
        assert_eq!(result, "7");
    }

    // ===== Conditionals =====

    #[test]
    fn test_conditional_true_branch() {
        let result = evaluate("if true then 1 else 2").unwrap();
        assert_eq!(result, "1");
    }

    #[test]
    fn test_conditional_false_branch() {
        let result = evaluate("if false then 1 else 2").unwrap();
        assert_eq!(result, "2");
    }

    // ===== String Interpolation =====

    #[test]
    fn test_string_interpolation() {
        let result = evaluate("let name = \"world\"; in \"hello ${name}\"").unwrap();
        assert_eq!(result, "\"hello world\"");
    }

    // ===== Error Cases =====

    #[test]
    fn test_invalid_syntax_error() {
        let result = evaluate("1 +");
        assert!(result.is_err());
    }

    #[test]
    fn test_run_no_args_error() {
        let result = run(None, None, false);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("provide --expr or --file"));
    }

    // ===== Derivation Parsing =====

    #[test]
    fn test_derivation_parsing() {
        let bytes: &[u8] = include_bytes!("../testdata/4wvvbi4jwn0prsdxb7vs673qa5h9gr7x-foo.drv");
        let trimmed = bytes.strip_suffix(b"\n").unwrap_or(bytes);

        let drv = nix_compat::derivation::Derivation::from_aterm_bytes(trimmed);
        assert!(drv.is_ok(), "failed to parse derivation: {:?}", drv.err());

        let drv = drv.unwrap();
        assert!(!drv.outputs.is_empty(), "derivation should have outputs");
    }

    // ===== Derivation Builtins (upstream) =====

    #[test]
    fn test_derivation_outpath() {
        let result = evaluate(
            r#"(derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/xpcvxsx5sw4rbq666blz6sxqlmsqphmr-foo""#
        );
    }

    #[test]
    fn test_derivation_drvpath() {
        let result = evaluate(
            r#"(derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).drvPath"#,
        ).unwrap();
        assert!(result.contains("/nix/store/"), "should be a store path");
        assert!(result.contains("-foo.drv"), "should be a .drv");
    }

    #[test]
    fn test_derivation_empty_name_fails() {
        let result = evaluate(
            r#"(derivation { name = ""; builder = "/bin/sh"; system = "x86_64-linux"; }).outPath"#,
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_fod_recursive_sha256() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHashMode = "recursive"; outputHashAlgo = "sha256"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/17wgs52s7kcamcyin4ja58njkf91ipq8-foo""#
        );
    }

    #[test]
    fn test_fod_recursive_sha256_other_name() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo2"; builder = "/bin/sh"; system = "x86_64-linux"; outputHashMode = "recursive"; outputHashAlgo = "sha256"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/gi0p8vd635vpk1nq029cz3aa3jkhar5k-foo2""#
        );
    }

    #[test]
    fn test_fod_flat_sha256() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHashMode = "flat"; outputHashAlgo = "sha256"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/q4pkwkxdib797fhk22p0k3g1q32jmxvf-foo""#
        );
    }

    #[test]
    fn test_fod_sha256_algo_omitted() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHashMode = "recursive"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/17wgs52s7kcamcyin4ja58njkf91ipq8-foo""#
        );
    }

    #[test]
    fn test_fod_sha256_mode_omitted() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/q4pkwkxdib797fhk22p0k3g1q32jmxvf-foo""#
        );
    }

    #[test]
    fn test_derivation_no_outputhash() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/xpcvxsx5sw4rbq666blz6sxqlmsqphmr-foo""#
        );
    }

    #[test]
    fn test_derivation_multiple_outputs() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; outputs = ["foo" "bar"]; system = "x86_64-linux"; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/hkwdinvz2jpzgnjy9lv34d2zxvclj4s3-foo-foo""#
        );
    }

    #[test]
    fn test_derivation_with_args() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; args = ["--foo" "42" "--bar"]; system = "x86_64-linux"; }).outPath"#,
        ).unwrap();
        assert_eq!(
            result,
            r#""/nix/store/365gi78n2z7vwc1bvgb98k0a9cqfp6as-foo""#
        );
    }

    #[test]
    fn test_derivation_with_dep() {
        let result = evaluate(
            r#"
            let
              bar = builtins.derivation {
                name = "bar";
                builder = ":";
                system = ":";
                outputHash = "08813cbee9903c62be4c5027726a418a300da4500b2d369d3af9286f4815ceba";
                outputHashAlgo = "sha256";
                outputHashMode = "recursive";
              };
            in
            (builtins.derivation {
              name = "foo";
              builder = ":";
              system = ":";
              inherit bar;
            }).outPath
        "#,
        )
        .unwrap();
        assert_eq!(
            result,
            r#""/nix/store/5vyvcwah9l9kf07d52rcgdk70g2f4y13-foo""#
        );
    }

    #[test]
    fn test_fod_same_hash_same_outpath() {
        let result = evaluate(r#"
            (builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath ==
            (builtins.derivation { name = "foo"; builder = "/bin/aa"; system = "x86_64-linux"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath
        "#).unwrap();
        assert_eq!(result, "true");
    }

    #[test]
    fn test_ignore_nulls_true() {
        let without = evaluate(
            r#"(builtins.derivation { name = "foo"; system = ":"; builder = ":"; __ignoreNulls = true; }).drvPath"#,
        ).unwrap();
        let with_null = evaluate(
            r#"(builtins.derivation { name = "foo"; system = ":"; builder = ":"; __ignoreNulls = true; ignoreme = null; }).drvPath"#,
        ).unwrap();
        assert_eq!(without, with_null);
    }

    #[test]
    fn test_placeholder() {
        let result = evaluate(r#"builtins.placeholder "out""#).unwrap();
        assert_eq!(
            result,
            r#""/1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9""#
        );
    }

    #[test]
    fn test_derivation_type_attr() {
        let result = evaluate(
            r#"(derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).type"#,
        )
        .unwrap();
        assert_eq!(result, r#""derivation""#);
    }

    #[test]
    fn test_derivation_duplicate_outputs_fails() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; outputs = ["foo" "foo"]; system = "x86_64-linux"; }).outPath"#,
        );
        assert!(result.is_err());
    }
}
