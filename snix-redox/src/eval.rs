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
use std::path::Path;
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

/// Evaluate a Nix expression from --expr or --file
pub fn run(
    expr: Option<String>,
    file: Option<String>,
    raw: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let source = match (expr, file) {
        (Some(e), _) => e,
        (_, Some(f)) => std::fs::read_to_string(&f)?,
        _ => return Err("provide --expr or --file".into()),
    };

    let result = evaluate(&source)?;
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
    evaluate_with_state_impl(expr, None)
}

/// Evaluate a build graph and publish its imported sources before executing builders.
/// Plain evaluation and dry runs keep their in-memory-only store behavior.
pub fn evaluate_for_build(
    expr: &str,
    db: &PathInfoDb,
) -> Result<(String, Rc<SnixStoreIO>), Box<dyn std::error::Error>> {
    evaluate_with_state_impl(
        expr,
        Some((db, Path::new(nix_compat::store_path::STORE_DIR))),
    )
}

fn evaluate_with_state_impl(
    expr: &str,
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

    let result = eval.evaluate(expr, None);

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

/// Build a `fetchGit` builtin that uses our git CLI-based fetch.
///
/// Accepts `{ url, rev?, ref?, narHash?, name? }` or a URL string.
/// Returns a store path string with Nix context.
fn make_fetchgit_builtin(io: Rc<SnixStoreIO>) -> Vec<(&'static str, snix_eval::Value)> {
    use snix_eval::generators::Gen;
    use snix_eval::{Builtin, ErrorKind, NixContext, NixContextElement, NixString, Value};

    let builtin = Builtin::new("fetchGit", None, 1, move |args| {
        let _io = io.clone();
        Gen::new(|_co| {
            let fut: std::pin::Pin<
                Box<dyn std::future::Future<Output = Result<Value, ErrorKind>>>,
            > = Box::pin(async move {
                let arg = args.into_iter().next().unwrap();

                // Parse args — either a string URL or an attrset
                let (url, rev, ref_, nar_hash, name) = if let Ok(s) = arg.to_str() {
                    let url_str =
                        String::from_utf8(s.as_bytes().to_vec()).map_err(|_| ErrorKind::Utf8)?;
                    (
                        url_str,
                        None::<String>,
                        None::<String>,
                        None::<String>,
                        "source".to_string(),
                    )
                } else {
                    let attrs = arg.to_attrs().map_err(|_| ErrorKind::TypeError {
                        expected: "attribute set or string",
                        actual: "other",
                    })?;

                    let url = attrs
                        .select("url")
                        .ok_or_else(|| ErrorKind::AttributeNotFound { name: "url".into() })?
                        .to_str()
                        .map_err(|_| ErrorKind::TypeError {
                            expected: "string",
                            actual: "other",
                        })?;
                    let url =
                        String::from_utf8(url.as_bytes().to_vec()).map_err(|_| ErrorKind::Utf8)?;

                    let rev = attrs
                        .select("rev")
                        .and_then(|v| v.to_str().ok())
                        .map(|s| String::from_utf8(s.as_bytes().to_vec()).unwrap_or_default());

                    let ref_ = attrs
                        .select("ref")
                        .and_then(|v| v.to_str().ok())
                        .map(|s| String::from_utf8(s.as_bytes().to_vec()).unwrap_or_default());

                    let nar_hash = attrs
                        .select("narHash")
                        .and_then(|v| v.to_str().ok())
                        .map(|s| String::from_utf8(s.as_bytes().to_vec()).unwrap_or_default());

                    let name = attrs
                        .select("name")
                        .and_then(|v| v.to_str().ok())
                        .map(|s| String::from_utf8(s.as_bytes().to_vec()).unwrap_or_default())
                        .unwrap_or_else(|| "source".to_string());

                    (url, rev, ref_, nar_hash, name)
                };

                // Resolve ref to rev if needed
                let resolved_rev = match (rev.as_deref(), ref_.as_deref()) {
                    (Some(r), _) => r.to_string(),
                    (None, Some(ref_name)) => crate::fetchers::resolve_git_ref(&url, ref_name)
                        .map_err(|e| {
                            ErrorKind::SnixError(std::sync::Arc::new(std::io::Error::other(
                                format!("fetchGit: {e}"),
                            )))
                        })?,
                    (None, None) => {
                        // Default to HEAD
                        crate::fetchers::resolve_git_ref(&url, "HEAD").map_err(|e| {
                            ErrorKind::SnixError(std::sync::Arc::new(std::io::Error::other(
                                format!("fetchGit: {e}"),
                            )))
                        })?
                    }
                };

                // Compute store path from narHash if available
                let store_path = if let Some(ref nar_hash_sri) = nar_hash {
                    use nix_compat::nixhash::{CAHash, HashAlgo, NixHash};
                    use nix_compat::store_path::build_ca_path;

                    let nix_hash = NixHash::from_str(nar_hash_sri, Some(HashAlgo::Sha256))
                        .map_err(|e| {
                            ErrorKind::SnixError(std::sync::Arc::new(std::io::Error::other(
                                format!("fetchGit: invalid narHash: {e}"),
                            )))
                        })?;
                    let ca_hash = CAHash::Nar(nix_hash);
                    let sp: nix_compat::store_path::StorePath<String> =
                        build_ca_path(&name, &ca_hash, std::iter::empty::<&str>(), false).map_err(
                            |e| {
                                ErrorKind::SnixError(std::sync::Arc::new(std::io::Error::other(
                                    format!("fetchGit: store path: {e}"),
                                )))
                            },
                        )?;
                    sp.to_absolute_path()
                } else {
                    // Without narHash, use a hash of url+rev for the path name
                    use sha2::{Digest, Sha256};
                    let hash_input = format!("git-{}-{}", url, resolved_rev);
                    let h = Sha256::digest(hash_input.as_bytes());
                    let hex = data_encoding::HEXLOWER.encode(&h);
                    format!("/nix/store/{}-{}", &hex[..32], name)
                };

                // Fetch if not cached
                crate::fetchers::fetch_git(&url, &resolved_rev, &store_path, nar_hash.as_deref())
                    .map_err(|e| {
                    ErrorKind::SnixError(std::sync::Arc::new(std::io::Error::other(format!(
                        "fetchGit: {e}"
                    ))))
                })?;

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
        let (_, state) = evaluate_with_state_impl(&expression, Some((&db, &store))).unwrap();
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
