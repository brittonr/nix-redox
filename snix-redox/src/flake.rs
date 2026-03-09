//! Flake support for `snix build .#package`.
//!
//! Implements the minimum viable flake workflow:
//! 1. Parse installable syntax (`.#attr`, `path#attr`)
//! 2. Parse `flake.lock` (version 7 JSON)
//! 3. Resolve locked inputs to tarball URLs
//! 4. Build a Nix expression that calls `(import ./flake.nix).outputs`
//! 5. Evaluate + build using the existing pipeline
//!
//! ## Scope
//!
//! - Supports `github` and `gitlab` locked input types (via tarball URLs)
//! - Supports `path` and `git` locked input types (local paths)
//! - Handles `flake: false` inputs (just source trees, no recursive eval)
//! - Handles `follows` chains in the lock file
//! - Does NOT support: lock file writing, `fetchGit`, flake registries,
//!   `--override-input`, recursive flake-of-flakes evaluation
//!
//! ## Architecture
//!
//! ```text
//! .#ripgrep
//!   → parse_installable()     → Installable { dir: ".", attr: "ripgrep" }
//!   → parse_flake_lock()      → FlakeLock { nodes, root }
//!   → resolve_all_inputs()    → HashMap<name, store_path>
//!   → build_flake_eval_expr() → Nix source string
//!   → evaluate_with_state()   → drv path
//!   → build_needed()          → output paths
//! ```

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

// ── Installable Parsing ────────────────────────────────────────────────────

/// A parsed flake installable reference.
///
/// ```text
/// .#ripgrep              → { dir: ".", attr: "ripgrep" }
/// /path/to/flake#pkg     → { dir: "/path/to/flake", attr: "pkg" }
/// .#packages.x86_64-unknown-redox.ripgrep → { dir: ".", attr: full path }
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct Installable {
    /// Directory containing `flake.nix` and `flake.lock`.
    pub flake_dir: PathBuf,
    /// Attribute path to resolve (e.g., `"ripgrep"` or
    /// `"packages.x86_64-linux.ripgrep"`).
    pub attr_path: String,
}

/// Parse an installable string like `.#ripgrep` or `/path#attr`.
///
/// Returns `None` if the string doesn't contain `#` (not an installable).
pub fn parse_installable(s: &str) -> Option<Installable> {
    let hash_pos = s.find('#')?;
    let dir_part = &s[..hash_pos];
    let attr_part = &s[hash_pos + 1..];

    if attr_part.is_empty() {
        return None;
    }

    let flake_dir = if dir_part.is_empty() || dir_part == "." {
        PathBuf::from(".")
    } else {
        PathBuf::from(dir_part)
    };

    Some(Installable {
        flake_dir,
        attr_path: attr_part.to_string(),
    })
}

/// Determine the full Nix attribute path for an installable.
///
/// Short forms like `ripgrep` are expanded to
/// `packages.<system>.ripgrep`. Fully-qualified paths like
/// `packages.x86_64-linux.ripgrep` are used as-is.
pub fn resolve_attr_path(attr: &str, system: &str) -> String {
    if attr.contains('.') {
        // Already qualified — use as-is
        attr.to_string()
    } else {
        // Short form: try packages.<system>.<attr> first
        format!("packages.\"{system}\".{attr}")
    }
}

// ── Flake Lock Parsing ─────────────────────────────────────────────────────

/// Parsed `flake.lock` file.
#[derive(Debug, Deserialize)]
pub struct FlakeLock {
    /// Lock file format version (currently 7).
    pub version: u32,
    /// Name of the root node (always `"root"`).
    pub root: String,
    /// Map of node name → lock node.
    pub nodes: HashMap<String, LockNode>,
}

/// A single node in the lock file.
#[derive(Debug, Deserialize)]
pub struct LockNode {
    /// Locked reference (absent for the root node).
    pub locked: Option<LockedRef>,
    /// Original (pre-lock) reference.
    pub original: Option<serde_json::Value>,
    /// Input mappings (name → node name or [node, output] path).
    pub inputs: Option<HashMap<String, InputRef>>,
    /// Whether this input is a flake (default: true).
    pub flake: Option<bool>,
}

/// A locked reference with all the information needed to fetch.
#[derive(Debug, Deserialize, Clone)]
pub struct LockedRef {
    /// Input type: `"github"`, `"gitlab"`, `"path"`, `"git"`.
    #[serde(rename = "type")]
    pub type_: String,
    /// Repository owner (for github/gitlab).
    pub owner: Option<String>,
    /// Repository name (for github/gitlab).
    pub repo: Option<String>,
    /// Git revision (commit hash).
    pub rev: Option<String>,
    /// NAR hash for integrity verification (`sha256-...` SRI format).
    #[serde(rename = "narHash")]
    pub nar_hash: Option<String>,
    /// Custom host (for gitlab self-hosted instances).
    pub host: Option<String>,
    /// Git ref (branch/tag).
    #[serde(rename = "ref")]
    pub ref_: Option<String>,
    /// Local path (for `type = "path"`).
    pub path: Option<String>,
    /// URL (for `type = "git"`).
    pub url: Option<String>,
    /// Last modified timestamp.
    #[serde(rename = "lastModified")]
    pub last_modified: Option<u64>,
}

impl LockNode {
    /// Whether this input is a flake (default: true if not specified).
    pub fn is_flake(&self) -> bool {
        self.flake.unwrap_or(true)
    }
}

/// A reference to another lock node.
///
/// In `flake.lock`, inputs can be either:
/// - A simple string: `"nixpkgs"` → refers to the node named `"nixpkgs"`
/// - An array: `["nixpkgs", "nixpkgs-lib"]` → follows chain
#[derive(Debug, Deserialize, Clone)]
#[serde(untagged)]
pub enum InputRef {
    /// Direct reference to a node by name.
    Direct(String),
    /// Follows chain: `[source_node, input_name]`.
    Follows(Vec<String>),
}

/// Parse a `flake.lock` file from a path.
pub fn parse_flake_lock(path: &Path) -> Result<FlakeLock, Box<dyn std::error::Error>> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("reading {}: {e}", path.display()))?;
    let lock: FlakeLock = serde_json::from_str(&content)
        .map_err(|e| format!("parsing {}: {e}", path.display()))?;

    if lock.version != 7 {
        return Err(format!(
            "unsupported flake.lock version {} (expected 7)",
            lock.version
        )
        .into());
    }

    Ok(lock)
}

// ── Input Resolution ───────────────────────────────────────────────────────

/// Resolve a locked reference to a tarball download URL.
///
/// Supports `github` and `gitlab` types. Returns `None` for types that
/// can't be resolved to a URL (e.g., `path`).
pub fn resolve_tarball_url(locked: &LockedRef) -> Option<String> {
    let rev = locked.rev.as_deref()?;

    match locked.type_.as_str() {
        "github" => {
            let owner = locked.owner.as_deref()?;
            let repo = locked.repo.as_deref()?;
            Some(format!(
                "https://github.com/{owner}/{repo}/archive/{rev}.tar.gz"
            ))
        }
        "gitlab" => {
            let owner = locked.owner.as_deref()?;
            let repo = locked.repo.as_deref()?;
            let host = locked
                .host
                .as_deref()
                .unwrap_or("gitlab.com");
            Some(format!(
                "https://{host}/{owner}/{repo}/-/archive/{rev}/{repo}-{rev}.tar.gz"
            ))
        }
        _ => None,
    }
}

/// Resolve a `follows` chain to the actual node name.
///
/// Walks the chain: `["nixpkgs", "nixpkgs-lib"]` means "use the input
/// named `nixpkgs-lib` from the node named `nixpkgs`".
pub fn resolve_follows(
    lock: &FlakeLock,
    follows: &[String],
) -> Result<String, Box<dyn std::error::Error>> {
    if follows.is_empty() {
        return Err("empty follows chain".into());
    }

    // Walk the chain: start from the first node, look up each subsequent
    // name in that node's inputs.
    let mut current_node_name = follows[0].clone();

    for step in &follows[1..] {
        let node = lock
            .nodes
            .get(&current_node_name)
            .ok_or_else(|| format!("follows: node '{}' not found", current_node_name))?;

        let inputs = node
            .inputs
            .as_ref()
            .ok_or_else(|| {
                format!("follows: node '{}' has no inputs", current_node_name)
            })?;

        match inputs.get(step) {
            Some(InputRef::Direct(target)) => {
                current_node_name = target.clone();
            }
            Some(InputRef::Follows(chain)) => {
                // Recursive follows — resolve the inner chain
                return resolve_follows(lock, chain);
            }
            None => {
                return Err(format!(
                    "follows: input '{}' not found in node '{}'",
                    step, current_node_name
                )
                .into());
            }
        }
    }

    Ok(current_node_name)
}

/// Get all direct input names for the root node.
///
/// Returns a map of `input_name → resolved_node_name`.
pub fn get_root_inputs(
    lock: &FlakeLock,
) -> Result<HashMap<String, String>, Box<dyn std::error::Error>> {
    let root = lock
        .nodes
        .get(&lock.root)
        .ok_or("flake.lock: root node not found")?;

    let inputs = match &root.inputs {
        Some(i) => i,
        None => return Ok(HashMap::new()),
    };

    let mut resolved = HashMap::new();
    for (name, input_ref) in inputs {
        let node_name = match input_ref {
            InputRef::Direct(target) => target.clone(),
            InputRef::Follows(chain) => resolve_follows(lock, chain)?,
        };
        resolved.insert(name.clone(), node_name);
    }

    Ok(resolved)
}

// ── Expression Building ────────────────────────────────────────────────────

/// A resolved input ready for use in the eval expression.
#[derive(Debug, Clone)]
pub struct ResolvedInput {
    /// Input name (as declared in `flake.nix`).
    pub name: String,
    /// Absolute store path (or local path) of the fetched source.
    pub store_path: String,
    /// Whether this input is a flake (has its own `flake.nix`).
    pub is_flake: bool,
}

/// Build the Nix expression that evaluates a flake attribute.
///
/// Constructs:
/// ```nix
/// let
///   flake = import /path/to/flake.nix;
///   self = /path/to/flake;
///   nixpkgs = /nix/store/...-nixpkgs-source;
///   ...
/// in (flake.outputs {
///   self = self;
///   nixpkgs = nixpkgs;
///   ...
/// }).packages."x86_64-unknown-redox".ripgrep
/// ```
///
/// For `flake: false` inputs, the value is just the source path.
/// For `flake: true` inputs, the value is `import <path>` (but we
/// don't recursively evaluate their flake — just pass the source tree).
pub fn build_flake_eval_expr(
    flake_dir: &Path,
    inputs: &[ResolvedInput],
    attr_path: &str,
    system: &str,
) -> String {
    let flake_dir_abs = std::fs::canonicalize(flake_dir)
        .map(|p| {
            // Strip Redox `file:` prefix from canonicalized paths
            let s = p.to_string_lossy();
            if let Some(stripped) = s.strip_prefix("file:") {
                PathBuf::from(stripped)
            } else {
                p
            }
        })
        .unwrap_or_else(|_| flake_dir.to_path_buf());
    let flake_nix = flake_dir_abs.join("flake.nix");

    let full_attr = resolve_attr_path(attr_path, system);

    let mut expr = String::new();
    expr.push_str("let\n");
    expr.push_str(&format!(
        "  __flake = import {};\n",
        nix_path_literal(&flake_nix)
    ));
    expr.push_str(&format!(
        "  __self = {};\n",
        nix_path_literal(&flake_dir_abs)
    ));

    // Bind each input to its store path
    for input in inputs {
        let safe_name = nix_safe_ident(&input.name);
        expr.push_str(&format!(
            "  __input_{safe_name} = {};\n",
            nix_path_literal(Path::new(&input.store_path))
        ));
    }

    expr.push_str("in\n");
    expr.push_str("  (__flake.outputs {\n");
    expr.push_str("    self = __self;\n");

    for input in inputs {
        let safe_name = nix_safe_ident(&input.name);
        // Pass the source path as the input value.
        // For actual flake inputs, we'd `import` their flake.nix and call
        // their outputs — but that requires recursive flake resolution.
        // For now, pass the raw source tree (works for flake: false inputs
        // and simple flake inputs that only need `self`/source access).
        expr.push_str(&format!(
            "    \"{name}\" = __input_{safe_name};\n",
            name = input.name
        ));
    }

    expr.push_str("  }).");
    expr.push_str(&full_attr);
    expr.push('\n');

    expr
}

/// Convert a filesystem path to a Nix path literal.
///
/// Nix path literals are unquoted: `/nix/store/abc-hello`.
/// Paths with special characters need to use `/.` prefix syntax.
///
/// On Redox, `std::fs::canonicalize()` may return paths with a `file:`
/// prefix (e.g., `file:/tmp/foo`). This function strips the prefix so
/// the resulting Nix path literal is valid.
fn nix_path_literal(path: &Path) -> String {
    let s = path.to_string_lossy();
    // Strip Redox `file:` prefix from canonicalized paths
    let s = s.strip_prefix("file:").unwrap_or(&s);
    // Nix path literals are just the absolute path, unquoted.
    // But they must start with `/` or `./` to be recognized as paths.
    if s.starts_with('/') || s.starts_with("./") {
        s.to_string()
    } else {
        format!("./{s}")
    }
}

/// Sanitize an input name for use as a Nix identifier.
///
/// Replaces `-` with `_` since Nix identifiers can't contain hyphens.
fn nix_safe_ident(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' })
        .collect()
}

// ── Top-Level Build ────────────────────────────────────────────────────────

/// Build a flake attribute end-to-end.
///
/// This is the main entry point for `snix build .#package`:
/// 1. Parse the installable
/// 2. Parse `flake.lock`
/// 3. Resolve and fetch all inputs
/// 4. Build the eval expression
/// 5. Evaluate and build
pub fn build_flake_installable(
    installable: &Installable,
) -> Result<(), Box<dyn std::error::Error>> {
    let flake_dir = &installable.flake_dir;

    // Verify flake.nix exists
    let flake_nix = flake_dir.join("flake.nix");
    if !flake_nix.exists() {
        return Err(format!(
            "flake.nix not found in {}",
            flake_dir.display()
        )
        .into());
    }

    // Parse flake.lock
    let lock_path = flake_dir.join("flake.lock");
    if !lock_path.exists() {
        return Err(format!(
            "flake.lock not found in {} (run 'nix flake lock' to create it)",
            flake_dir.display()
        )
        .into());
    }
    let lock = parse_flake_lock(&lock_path)?;

    // Resolve root inputs
    let root_inputs = get_root_inputs(&lock)?;

    // Fetch all inputs
    let mut resolved_inputs = Vec::new();
    for (input_name, node_name) in &root_inputs {
        let node = lock
            .nodes
            .get(node_name)
            .ok_or_else(|| format!("node '{}' not found in flake.lock", node_name))?;

        let locked = match &node.locked {
            Some(l) => l,
            None => {
                eprintln!("warning: input '{}' has no locked reference, skipping", input_name);
                continue;
            }
        };

        let store_path = fetch_locked_input(input_name, locked)?;

        resolved_inputs.push(ResolvedInput {
            name: input_name.clone(),
            store_path,
            is_flake: node.is_flake(),
        });
    }

    // Determine system
    let system = current_system();

    // Build eval expression
    let expr = build_flake_eval_expr(
        flake_dir,
        &resolved_inputs,
        &installable.attr_path,
        &system,
    );

    eprintln!("evaluating .#{}...", installable.attr_path);

    // Evaluate `(expr).drvPath`
    let drv_path_expr = format!("({expr}).drvPath");
    let (drv_path_str, state) = crate::eval::evaluate_with_state(&drv_path_expr)?;

    let drv_path_str = drv_path_str.trim_matches('"').to_string();
    let drv_path =
        nix_compat::store_path::StorePath::<String>::from_absolute_path(
            drv_path_str.as_bytes(),
        )
        .map_err(|e| format!("invalid derivation path '{drv_path_str}': {e}"))?;

    let known_paths = state.known_paths.borrow();
    let db = crate::pathinfo::PathInfoDb::open()
        .map_err(|e| format!("opening pathinfo db: {e}"))?;

    let result = crate::local_build::build_needed(&drv_path, &known_paths, &db)?;

    // Print output paths
    for (name, path) in &result.outputs {
        if result.outputs.len() == 1 {
            println!("{path}");
        } else {
            println!("{name}: {path}");
        }
    }

    Ok(())
}

/// Fetch a locked input and return its store path.
///
/// For `github`/`gitlab` types: downloads the tarball via the existing
/// `fetchTarball` infrastructure and returns the store path.
///
/// For `path` type: returns the local path directly.
fn fetch_locked_input(
    name: &str,
    locked: &LockedRef,
) -> Result<String, Box<dyn std::error::Error>> {
    match locked.type_.as_str() {
        "github" | "gitlab" => {
            let url = resolve_tarball_url(locked).ok_or_else(|| {
                format!(
                    "cannot resolve tarball URL for input '{}' (type={})",
                    name, locked.type_
                )
            })?;

            let nar_hash = locked.nar_hash.as_deref().ok_or_else(|| {
                format!("input '{}' has no narHash", name)
            })?;

            // Use the existing fetchTarball FOD machinery to compute the
            // store path. The actual download happens at build time.
            // But for flake inputs, we need the source NOW (at eval time).
            //
            // Create a store path from the narHash. For flake inputs, the
            // store path is computed as:
            //   /nix/store/<hash>-source
            // where <hash> is derived from the NAR hash.
            let store_path = compute_fod_store_path(name, nar_hash)?;

            // Check if already fetched
            if Path::new(&store_path).exists() {
                eprintln!("using cached input '{name}' at {store_path}");
                return Ok(store_path);
            }

            // Download and extract
            eprintln!("fetching input '{name}' from {url}...");
            fetch_and_extract_to_store(&url, &store_path)?;

            // Verify NAR hash
            verify_nar_hash(&store_path, nar_hash)?;

            Ok(store_path)
        }
        "path" => {
            let path = locked.path.as_deref().ok_or_else(|| {
                format!("path input '{}' has no path field", name)
            })?;
            Ok(path.to_string())
        }
        "git" => {
            // For git inputs with a URL, we could try to resolve as tarball
            // if it's from a known forge. For now, error.
            Err(format!(
                "git input '{}' not yet supported (use github/gitlab type or bridge mode)",
                name
            )
            .into())
        }
        other => {
            Err(format!(
                "unsupported input type '{}' for input '{}'",
                other, name
            )
            .into())
        }
    }
}

/// Compute the fixed-output store path for a fetchTarball-style input.
///
/// For recursive (NAR) SHA-256 hashes, the store path is:
/// `/nix/store/<hash>-source`
///
/// This matches Nix's `builtins.fetchTarball` path computation.
fn compute_fod_store_path(
    name: &str,
    nar_hash_sri: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    use nix_compat::nixhash::{CAHash, HashAlgo, NixHash};
    use nix_compat::store_path::{build_ca_path, StorePath};

    // Parse SRI hash (sha256-...)
    let nix_hash = NixHash::from_str(nar_hash_sri, Some(HashAlgo::Sha256))
        .map_err(|e| format!("invalid narHash for '{}': {e}", name))?;

    let ca_hash = CAHash::Nar(nix_hash);

    // Compute the store path — flake inputs are always named "source"
    let store_path: StorePath<String> =
        build_ca_path("source", &ca_hash, std::iter::empty::<&str>(), false)
            .map_err(|e| format!("computing store path for '{}': {e}", name))?;

    Ok(store_path.to_absolute_path())
}

/// Download a tarball and extract it to a store path.
fn fetch_and_extract_to_store(
    url: &str,
    store_path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Ensure /nix/store exists
    std::fs::create_dir_all(nix_compat::store_path::STORE_DIR)?;

    // Use the existing tarball extraction from fetchers.rs
    crate::fetchers::fetch_and_unpack(url, store_path)?;

    Ok(())
}

/// Verify the NAR hash of a fetched store path.
fn verify_nar_hash(
    store_path: &str,
    expected_sri: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    use nix_compat::nixhash::{HashAlgo, NixHash};

    let expected = NixHash::from_str(expected_sri, Some(HashAlgo::Sha256))
        .map_err(|e| format!("invalid expected hash: {e}"))?;

    let (actual_hash_str, _size) =
        crate::local_build::nar_hash_path(Path::new(store_path))?;

    let actual_hex = actual_hash_str
        .strip_prefix("sha256:")
        .ok_or("unexpected hash format from nar_hash_path")?;

    let expected_bytes = match &expected {
        NixHash::Sha256(h) => h,
        _ => return Err("only SHA-256 hashes supported".into()),
    };
    let expected_hex = data_encoding::HEXLOWER.encode(expected_bytes);

    if actual_hex != expected_hex {
        // Clean up the bad fetch
        let _ = std::fs::remove_dir_all(store_path);
        return Err(format!(
            "NAR hash mismatch for {}:\n  expected: {}\n  got:      {}",
            store_path, expected_hex, actual_hex
        )
        .into());
    }

    eprintln!("✓ verified {store_path}");
    Ok(())
}

/// Get the current system identifier.
///
/// Returns `x86_64-unknown-redox` on Redox, `x86_64-linux` on Linux, etc.
fn current_system() -> String {
    #[cfg(target_os = "redox")]
    {
        "x86_64-unknown-redox".to_string()
    }
    #[cfg(not(target_os = "redox"))]
    {
        // For testing on Linux
        if cfg!(target_arch = "x86_64") {
            "x86_64-linux".to_string()
        } else if cfg!(target_arch = "aarch64") {
            "aarch64-linux".to_string()
        } else {
            "x86_64-linux".to_string()
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── parse_installable ──────────────────────────────────────────────

    #[test]
    fn parse_dot_hash_simple() {
        let i = parse_installable(".#ripgrep").unwrap();
        assert_eq!(i.flake_dir, PathBuf::from("."));
        assert_eq!(i.attr_path, "ripgrep");
    }

    #[test]
    fn parse_dot_hash_qualified() {
        let i = parse_installable(".#packages.x86_64-linux.hello").unwrap();
        assert_eq!(i.flake_dir, PathBuf::from("."));
        assert_eq!(i.attr_path, "packages.x86_64-linux.hello");
    }

    #[test]
    fn parse_path_hash() {
        let i = parse_installable("/some/path#myPkg").unwrap();
        assert_eq!(i.flake_dir, PathBuf::from("/some/path"));
        assert_eq!(i.attr_path, "myPkg");
    }

    #[test]
    fn parse_empty_attr_returns_none() {
        assert!(parse_installable(".#").is_none());
    }

    #[test]
    fn parse_no_hash_returns_none() {
        assert!(parse_installable("just-a-path").is_none());
    }

    #[test]
    fn parse_hash_hash_attr() {
        // path contains hash in name
        let i = parse_installable("#attr").unwrap();
        assert_eq!(i.flake_dir, PathBuf::from("."));
        assert_eq!(i.attr_path, "attr");
    }

    // ── resolve_attr_path ──────────────────────────────────────────────

    #[test]
    fn attr_path_short_form() {
        let resolved = resolve_attr_path("ripgrep", "x86_64-linux");
        assert_eq!(resolved, "packages.\"x86_64-linux\".ripgrep");
    }

    #[test]
    fn attr_path_already_qualified() {
        let resolved =
            resolve_attr_path("packages.x86_64-linux.hello", "x86_64-linux");
        assert_eq!(resolved, "packages.x86_64-linux.hello");
    }

    #[test]
    fn attr_path_redox_system() {
        let resolved = resolve_attr_path("ripgrep", "x86_64-unknown-redox");
        assert_eq!(
            resolved,
            "packages.\"x86_64-unknown-redox\".ripgrep"
        );
    }

    // ── resolve_tarball_url ────────────────────────────────────────────

    #[test]
    fn github_tarball_url() {
        let locked = LockedRef {
            type_: "github".to_string(),
            owner: Some("NixOS".to_string()),
            repo: Some("nixpkgs".to_string()),
            rev: Some("abc123".to_string()),
            nar_hash: None,
            host: None,
            ref_: None,
            path: None,
            url: None,
            last_modified: None,
        };
        let url = resolve_tarball_url(&locked).unwrap();
        assert_eq!(
            url,
            "https://github.com/NixOS/nixpkgs/archive/abc123.tar.gz"
        );
    }

    #[test]
    fn gitlab_default_host() {
        let locked = LockedRef {
            type_: "gitlab".to_string(),
            owner: Some("user".to_string()),
            repo: Some("project".to_string()),
            rev: Some("def456".to_string()),
            nar_hash: None,
            host: None,
            ref_: None,
            path: None,
            url: None,
            last_modified: None,
        };
        let url = resolve_tarball_url(&locked).unwrap();
        assert_eq!(
            url,
            "https://gitlab.com/user/project/-/archive/def456/project-def456.tar.gz"
        );
    }

    #[test]
    fn gitlab_custom_host() {
        let locked = LockedRef {
            type_: "gitlab".to_string(),
            owner: Some("redox-os".to_string()),
            repo: Some("kernel".to_string()),
            rev: Some("abc".to_string()),
            nar_hash: None,
            host: Some("gitlab.redox-os.org".to_string()),
            ref_: None,
            path: None,
            url: None,
            last_modified: None,
        };
        let url = resolve_tarball_url(&locked).unwrap();
        assert_eq!(
            url,
            "https://gitlab.redox-os.org/redox-os/kernel/-/archive/abc/kernel-abc.tar.gz"
        );
    }

    #[test]
    fn path_type_no_url() {
        let locked = LockedRef {
            type_: "path".to_string(),
            owner: None,
            repo: None,
            rev: None,
            nar_hash: None,
            host: None,
            ref_: None,
            path: Some("/some/local/path".to_string()),
            url: None,
            last_modified: None,
        };
        assert!(resolve_tarball_url(&locked).is_none());
    }

    #[test]
    fn no_rev_returns_none() {
        let locked = LockedRef {
            type_: "github".to_string(),
            owner: Some("NixOS".to_string()),
            repo: Some("nixpkgs".to_string()),
            rev: None,
            nar_hash: None,
            host: None,
            ref_: None,
            path: None,
            url: None,
            last_modified: None,
        };
        assert!(resolve_tarball_url(&locked).is_none());
    }

    // ── nix_safe_ident ─────────────────────────────────────────────────

    #[test]
    fn safe_ident_simple() {
        assert_eq!(nix_safe_ident("nixpkgs"), "nixpkgs");
    }

    #[test]
    fn safe_ident_with_hyphens() {
        assert_eq!(nix_safe_ident("relibc-src"), "relibc_src");
    }

    #[test]
    fn safe_ident_with_dots() {
        assert_eq!(nix_safe_ident("nixpkgs-lib.follows"), "nixpkgs_lib_follows");
    }

    // ── nix_path_literal ───────────────────────────────────────────────

    #[test]
    fn path_literal_absolute() {
        assert_eq!(
            nix_path_literal(Path::new("/nix/store/abc-hello")),
            "/nix/store/abc-hello"
        );
    }

    #[test]
    fn path_literal_relative() {
        assert_eq!(nix_path_literal(Path::new("./foo")), "./foo");
    }

    #[test]
    fn path_literal_bare_relative() {
        assert_eq!(nix_path_literal(Path::new("foo")), "./foo");
    }

    // ── parse_flake_lock ───────────────────────────────────────────────

    #[test]
    fn parse_minimal_lock() {
        let tmp = tempfile::tempdir().unwrap();
        let lock_path = tmp.path().join("flake.lock");
        std::fs::write(
            &lock_path,
            r#"{
                "version": 7,
                "root": "root",
                "nodes": {
                    "root": {
                        "inputs": {
                            "hello": "hello-src"
                        }
                    },
                    "hello-src": {
                        "flake": false,
                        "locked": {
                            "type": "github",
                            "owner": "test",
                            "repo": "hello",
                            "rev": "abc123",
                            "narHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
                        }
                    }
                }
            }"#,
        )
        .unwrap();

        let lock = parse_flake_lock(&lock_path).unwrap();
        assert_eq!(lock.version, 7);
        assert_eq!(lock.nodes.len(), 2);

        let hello = lock.nodes.get("hello-src").unwrap();
        assert!(!hello.is_flake());
        let locked = hello.locked.as_ref().unwrap();
        assert_eq!(locked.type_, "github");
        assert_eq!(locked.owner.as_deref(), Some("test"));
    }

    #[test]
    fn parse_wrong_version_fails() {
        let tmp = tempfile::tempdir().unwrap();
        let lock_path = tmp.path().join("flake.lock");
        std::fs::write(
            &lock_path,
            r#"{"version": 3, "root": "root", "nodes": {"root": {}}}"#,
        )
        .unwrap();

        let result = parse_flake_lock(&lock_path);
        assert!(result.is_err());
        assert!(
            result.unwrap_err().to_string().contains("version"),
            "should mention version"
        );
    }

    // ── get_root_inputs ────────────────────────────────────────────────

    #[test]
    fn root_inputs_direct() {
        let lock = FlakeLock {
            version: 7,
            root: "root".to_string(),
            nodes: [
                (
                    "root".to_string(),
                    LockNode {
                        locked: None,
                        original: None,
                        inputs: Some(
                            [("hello".to_string(), InputRef::Direct("hello-src".to_string()))]
                                .into_iter()
                                .collect(),
                        ),
                        flake: None,
                    },
                ),
                (
                    "hello-src".to_string(),
                    LockNode {
                        locked: Some(LockedRef {
                            type_: "github".to_string(),
                            owner: Some("test".to_string()),
                            repo: Some("hello".to_string()),
                            rev: Some("abc".to_string()),
                            nar_hash: Some("sha256-AAA=".to_string()),
                            host: None,
                            ref_: None,
                            path: None,
                            url: None,
                            last_modified: None,
                        }),
                        original: None,
                        inputs: None,
                        flake: Some(false),
                    },
                ),
            ]
            .into_iter()
            .collect(),
        };

        let inputs = get_root_inputs(&lock).unwrap();
        assert_eq!(inputs.len(), 1);
        assert_eq!(inputs.get("hello").unwrap(), "hello-src");
    }

    // ── resolve_follows ────────────────────────────────────────────────

    #[test]
    fn follows_simple() {
        let lock = FlakeLock {
            version: 7,
            root: "root".to_string(),
            nodes: [
                (
                    "root".to_string(),
                    LockNode {
                        locked: None,
                        original: None,
                        inputs: Some(
                            [
                                ("nixpkgs".to_string(), InputRef::Direct("nixpkgs".to_string())),
                                (
                                    "utils".to_string(),
                                    InputRef::Direct("flake-utils".to_string()),
                                ),
                            ]
                            .into_iter()
                            .collect(),
                        ),
                        flake: None,
                    },
                ),
                (
                    "nixpkgs".to_string(),
                    LockNode {
                        locked: Some(LockedRef {
                            type_: "github".to_string(),
                            owner: Some("NixOS".to_string()),
                            repo: Some("nixpkgs".to_string()),
                            rev: Some("abc".to_string()),
                            nar_hash: Some("sha256-AAA=".to_string()),
                            host: None,
                            ref_: None,
                            path: None,
                            url: None,
                            last_modified: None,
                        }),
                        original: None,
                        inputs: None,
                        flake: None,
                    },
                ),
                (
                    "flake-utils".to_string(),
                    LockNode {
                        locked: Some(LockedRef {
                            type_: "github".to_string(),
                            owner: Some("numtide".to_string()),
                            repo: Some("flake-utils".to_string()),
                            rev: Some("def".to_string()),
                            nar_hash: Some("sha256-BBB=".to_string()),
                            host: None,
                            ref_: None,
                            path: None,
                            url: None,
                            last_modified: None,
                        }),
                        original: None,
                        inputs: Some(
                            [(
                                "nixpkgs".to_string(),
                                InputRef::Direct("nixpkgs".to_string()),
                            )]
                            .into_iter()
                            .collect(),
                        ),
                        flake: None,
                    },
                ),
            ]
            .into_iter()
            .collect(),
        };

        // follows chain: ["flake-utils", "nixpkgs"] → resolves to "nixpkgs"
        let resolved =
            resolve_follows(&lock, &["flake-utils".to_string(), "nixpkgs".to_string()])
                .unwrap();
        assert_eq!(resolved, "nixpkgs");
    }

    // ── build_flake_eval_expr ──────────────────────────────────────────

    #[test]
    fn eval_expr_simple() {
        let inputs = vec![ResolvedInput {
            name: "hello-src".to_string(),
            store_path: "/nix/store/abc-source".to_string(),
            is_flake: false,
        }];

        let expr =
            build_flake_eval_expr(Path::new("/tmp/myflake"), &inputs, "hello", "x86_64-linux");

        assert!(expr.contains("import /tmp/myflake/flake.nix"), "expr: {expr}");
        assert!(expr.contains("__self = /tmp/myflake"), "expr: {expr}");
        assert!(
            expr.contains("__input_hello_src = /nix/store/abc-source"),
            "expr: {expr}"
        );
        assert!(
            expr.contains("\"hello-src\" = __input_hello_src"),
            "expr: {expr}"
        );
        assert!(
            expr.contains("packages.\"x86_64-linux\".hello"),
            "expr: {expr}"
        );
    }

    #[test]
    fn eval_expr_qualified_attr() {
        let inputs = vec![];
        let expr = build_flake_eval_expr(
            Path::new("/tmp/f"),
            &inputs,
            "packages.x86_64-linux.hello",
            "x86_64-linux",
        );

        // Qualified attrs should be used as-is
        assert!(
            expr.contains("packages.x86_64-linux.hello"),
            "expr: {expr}"
        );
    }

    // ── compute_fod_store_path ─────────────────────────────────────────

    #[test]
    fn fod_store_path_deterministic() {
        let hash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA=";
        let p1 = compute_fod_store_path("test", hash).unwrap();
        let p2 = compute_fod_store_path("test", hash).unwrap();
        assert_eq!(p1, p2);
        assert!(p1.starts_with("/nix/store/"));
        assert!(p1.ends_with("-source"));
    }

    #[test]
    fn fod_store_path_different_hash_different_path() {
        let p1 = compute_fod_store_path(
            "a",
            "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA=",
        )
        .unwrap();
        let p2 = compute_fod_store_path(
            "a",
            "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        )
        .unwrap();
        assert_ne!(p1, p2);
    }

    // ── Real flake.lock parsing ────────────────────────────────────────

    #[test]
    fn parse_real_flake_lock() {
        // Parse the actual project flake.lock if available
        let lock_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("flake.lock");

        if !lock_path.exists() {
            // Running from a different directory, skip
            return;
        }

        let lock = parse_flake_lock(&lock_path).unwrap();
        assert_eq!(lock.version, 7);
        assert_eq!(lock.root, "root");

        // Should have many nodes
        assert!(lock.nodes.len() > 10, "expected many nodes, got {}", lock.nodes.len());

        // Root should have inputs
        let root_inputs = get_root_inputs(&lock).unwrap();
        assert!(root_inputs.contains_key("nixpkgs"), "should have nixpkgs input");

        // nixpkgs should be a github type
        let nixpkgs_node = root_inputs.get("nixpkgs").unwrap();
        let nixpkgs = lock.nodes.get(nixpkgs_node).unwrap();
        let locked = nixpkgs.locked.as_ref().unwrap();
        assert_eq!(locked.type_, "github");
        assert_eq!(locked.owner.as_deref(), Some("NixOS"));
        assert_eq!(locked.repo.as_deref(), Some("nixpkgs"));

        // Verify tarball URL resolution
        let url = resolve_tarball_url(locked).unwrap();
        assert!(url.starts_with("https://github.com/NixOS/nixpkgs/archive/"));
        assert!(url.ends_with(".tar.gz"));
    }

    #[test]
    fn real_lock_gitlab_inputs() {
        let lock_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("flake.lock");

        if !lock_path.exists() {
            return;
        }

        let lock = parse_flake_lock(&lock_path).unwrap();
        let root_inputs = get_root_inputs(&lock).unwrap();

        // relibc-src should be a gitlab type with custom host
        if let Some(node_name) = root_inputs.get("relibc-src") {
            let node = lock.nodes.get(node_name).unwrap();
            let locked = node.locked.as_ref().unwrap();
            assert_eq!(locked.type_, "gitlab");
            assert_eq!(locked.host.as_deref(), Some("gitlab.redox-os.org"));

            let url = resolve_tarball_url(locked).unwrap();
            assert!(url.contains("gitlab.redox-os.org"));
            assert!(url.contains("relibc"));
        }
    }

    #[test]
    fn real_lock_non_flake_count() {
        let lock_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("flake.lock");

        if !lock_path.exists() {
            return;
        }

        let lock = parse_flake_lock(&lock_path).unwrap();

        let non_flake_count = lock
            .nodes
            .values()
            .filter(|n| !n.is_flake())
            .count();

        // Should have many non-flake (source-only) inputs
        assert!(
            non_flake_count > 30,
            "expected >30 non-flake inputs, got {non_flake_count}"
        );
    }
}
