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
//! - Supports `path`, `git` and `tarball` locked input types
//! - Evaluates flake inputs recursively, with `self`, `sourceInfo`, `inputs`,
//!   `outputs` and lock metadata, including `follows`
//! - Handles `flake: false` inputs as plain source trees
//! - `git` inputs: tries forge tarball first (GitHub/GitLab), falls back to git clone
//! - Does NOT support: lock file writing, flake registries, `--override-input`
//!
//! ## Architecture
//!
//! ```text
//! .#ripgrep
//!   → parse_installable()     → Installable { dir: ".", attr: "ripgrep" }
//!   → parse_flake_lock()      → FlakeLock { nodes, root }
//!   → resolve_flake_nodes()   → reachable nodes + fetched sources
//!   → build_flake_eval_expr() → recursive Nix source string
//!   → evaluate_with_state()   → drv path
//!   → build_needed()          → output paths
//! ```

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::system::current_system;

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
    let content =
        std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    let lock: FlakeLock =
        serde_json::from_str(&content).map_err(|e| format!("parsing {}: {e}", path.display()))?;

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
            let host = locked.host.as_deref().unwrap_or("gitlab.com");
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

    // A `follows` path starts at the root node, exactly as flake-compat and
    // `nix/nixtamal.nix` interpret it, and each step names that node's input.
    follow_from(lock, &lock.root, follows)
}

fn follow_from(
    lock: &FlakeLock,
    start: &str,
    follows: &[String],
) -> Result<String, Box<dyn std::error::Error>> {
    let mut current_node_name = start.to_string();

    for step in follows {
        let node = lock
            .nodes
            .get(&current_node_name)
            .ok_or_else(|| format!("follows: node '{}' not found", current_node_name))?;

        let inputs = node
            .inputs
            .as_ref()
            .ok_or_else(|| format!("follows: node '{}' has no inputs", current_node_name))?;

        match inputs.get(step) {
            Some(InputRef::Direct(target)) => {
                current_node_name = target.clone();
            }
            Some(InputRef::Follows(chain)) => {
                current_node_name = resolve_follows(lock, chain)?;
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

/// Resolve one input reference from a node to the lock node it names.
fn resolve_input_ref(
    lock: &FlakeLock,
    input: &InputRef,
) -> Result<String, Box<dyn std::error::Error>> {
    let node_name = match input {
        InputRef::Direct(target) => target.clone(),
        InputRef::Follows(chain) => resolve_follows(lock, chain)?,
    };
    if !lock.nodes.contains_key(&node_name) {
        return Err(format!("input names unknown node '{node_name}'").into());
    }
    Ok(node_name)
}

/// Every lock node reachable from the root through resolved inputs.
fn reachable_nodes(lock: &FlakeLock) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let mut seen = HashSet::new();
    let mut queue = VecDeque::from([lock.root.clone()]);
    let mut ordered = Vec::new();

    while let Some(name) = queue.pop_front() {
        if !seen.insert(name.clone()) {
            continue;
        }
        let node = lock
            .nodes
            .get(&name)
            .ok_or_else(|| format!("node '{name}' not found in flake.lock"))?;
        if let Some(inputs) = &node.inputs {
            for input in inputs.values() {
                queue.push_back(resolve_input_ref(lock, input)?);
            }
        }
        ordered.push(name);
    }

    ordered.sort();
    Ok(ordered)
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

/// A reachable lock node with its fetched source and resolved input edges.
#[derive(Debug, Clone)]
pub struct ResolvedNode {
    /// Lock node key (`"root"`, `"nixpkgs"`, ...).
    pub name: String,
    /// Absolute store path (or local path) of the fetched source.
    pub store_path: String,
    /// Whether this input is a flake (has its own `flake.nix`).
    pub is_flake: bool,
    /// Declared input name → resolved lock node key.
    pub inputs: HashMap<String, String>,
    /// Locked source metadata, absent for the root node.
    pub locked: Option<LockedRef>,
    /// Whether this is the flake being built.
    pub is_root: bool,
}

/// Build the Nix expression that evaluates a flake attribute.
///
/// Every reachable lock node is wired the way flake-compat and
/// `nix/nixtamal.nix` wire it: each flake calls its own `outputs` with `self`
/// and its resolved inputs, and exposes `outPath`, `sourceInfo`, `inputs`,
/// `outputs`, `_type`, and the lock's `rev`/`narHash` metadata. Inputs whose
/// lock node says `flake = false` stay plain source trees.
pub fn build_flake_eval_expr(
    flake_dir: &Path,
    nodes: &[ResolvedNode],
    attr_path: &str,
    system: &str,
) -> Result<String, Box<dyn std::error::Error>> {
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

    let root_name = nodes
        .iter()
        .find(|node| node.is_root)
        .map(|node| node.name.as_str())
        .ok_or("flake expression has no root node")?;
    let full_attr = resolve_attr_path(attr_path, system);

    // A recursive `nodes` attrset mirrors flake-compat and `nix/nixtamal.nix`.
    // Each flake node evaluates its own outputs with `self` and its resolved
    // inputs, then exposes the outputs merged with source metadata.
    let mut expr = String::new();
    expr.push_str("let\n");
    expr.push_str("  __nodes = {\n");

    for node in nodes {
        let source = if node.is_root {
            flake_dir_abs.clone()
        } else {
            PathBuf::from(&node.store_path)
        };

        expr.push_str(&format!("    {} = ", nix_string_literal(&node.name)));
        if !node.is_flake {
            expr.push_str(&format!("{};\n", nix_path_literal(&source)));
            continue;
        }

        expr.push_str("let\n");
        push_node_info(&mut expr, "      ", &source, node.locked.as_ref());

        expr.push_str("      __inputs = {\n");
        let mut input_names: Vec<_> = node.inputs.iter().collect();
        input_names.sort_by_key(|(name, _)| *name);
        for (name, target) in input_names {
            if !nodes.iter().any(|node| node.name == *target) {
                return Err(format!(
                    "input '{name}' of '{}' names unknown node '{target}'",
                    node.name
                )
                .into());
            }
            expr.push_str(&format!(
                "        {} = __nodes.{};\n",
                nix_string_literal(name),
                nix_string_literal(target)
            ));
        }
        expr.push_str("      };\n");

        expr.push_str(&format!(
            "      __outputs = (import {}).outputs (__inputs // {{ self = __self; }});\n",
            nix_path_literal(&source.join("flake.nix"))
        ));
        expr.push_str("      __self = __info // {\n");
        expr.push_str("        inputs = __inputs;\n");
        expr.push_str("        outputs = __outputs;\n");
        expr.push_str("        _type = \"flake\";\n");
        expr.push_str("      };\n");
        expr.push_str("      __flake = __outputs // __self;\n");
        expr.push_str("    in __flake;\n");
    }

    expr.push_str("  };\n");
    expr.push_str("in\n");
    expr.push_str(&format!(
        "  __nodes.{}.{full_attr}\n",
        nix_string_literal(root_name)
    ));

    Ok(expr)
}

/// Resolve every lock node reachable from the root and fetch its source.
///
/// Flake inputs are evaluated recursively, so every reachable node needs a
/// source tree. `flake = false` nodes are still fetched and bound as plain
/// paths; only their `flake.nix` is never imported.
pub fn resolve_flake_nodes(
    lock: &FlakeLock,
    flake_dir: &Path,
) -> Result<Vec<ResolvedNode>, Box<dyn std::error::Error>> {
    let mut resolved = Vec::new();

    for name in reachable_nodes(lock)? {
        let node = lock
            .nodes
            .get(&name)
            .ok_or_else(|| format!("node '{name}' not found in flake.lock"))?;
        let is_root = name == lock.root;

        let inputs = node
            .inputs
            .as_ref()
            .map(|inputs| {
                inputs
                    .iter()
                    .map(|(input_name, input_ref)| {
                        Ok((input_name.clone(), resolve_input_ref(lock, input_ref)?))
                    })
                    .collect::<Result<HashMap<_, _>, Box<dyn std::error::Error>>>()
            })
            .transpose()?
            .unwrap_or_default();

        if is_root {
            resolved.push(ResolvedNode {
                name,
                store_path: flake_dir.to_string_lossy().to_string(),
                is_flake: true,
                inputs,
                locked: None,
                is_root: true,
            });
            continue;
        }

        let locked = node
            .locked
            .as_ref()
            .ok_or_else(|| format!("input node '{name}' has no locked reference"))?;
        let store_path = fetch_locked_input(&name, locked, flake_dir)?;

        resolved.push(ResolvedNode {
            name,
            store_path,
            is_flake: node.is_flake(),
            inputs,
            locked: Some(locked.clone()),
            is_root: false,
        });
    }

    Ok(resolved)
}

fn push_node_info(expr: &mut String, indent: &str, source: &Path, locked: Option<&LockedRef>) {
    let out_path = nix_path_literal(source);
    let rev = locked.and_then(|l| l.rev.as_deref());
    let short_rev = rev.map(|rev| &rev[..rev.len().min(7)]);
    let nar_hash = locked.and_then(|l| l.nar_hash.as_deref());
    let last_modified = locked.and_then(|l| l.last_modified);

    let mut metadata = Vec::new();
    if let Some(rev) = rev {
        metadata.push(format!("rev = {};", nix_string_literal(rev)));
    }
    if let Some(short_rev) = short_rev {
        metadata.push(format!("shortRev = {};", nix_string_literal(short_rev)));
    }
    if let Some(last_modified) = last_modified {
        metadata.push(format!("lastModified = {last_modified};"));
    }
    if let Some(nar_hash) = nar_hash {
        metadata.push(format!("narHash = {};", nix_string_literal(nar_hash)));
    }

    expr.push_str(&format!("{indent}__info = {{\n"));
    expr.push_str(&format!("{indent}  outPath = {out_path};\n"));
    expr.push_str(&format!("{indent}  sourceInfo = {{\n"));
    expr.push_str(&format!("{indent}    outPath = {out_path};\n"));
    for line in &metadata {
        expr.push_str(&format!("{indent}    {line}\n"));
    }
    expr.push_str(&format!("{indent}  }};\n"));
    for line in &metadata {
        expr.push_str(&format!("{indent}  {line}\n"));
    }
    expr.push_str(&format!("{indent}}};\n"));
}

fn nix_string_literal(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 2);
    escaped.push('"');
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            '$' if chars.peek() == Some(&'{') => escaped.push_str("\\$"),
            _ => escaped.push(c),
        }
    }
    escaped.push('"');
    escaped
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
    no_sandbox: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let flake_dir = &installable.flake_dir;

    // Verify flake.nix exists
    let flake_nix = flake_dir.join("flake.nix");
    if !flake_nix.exists() {
        return Err(format!("flake.nix not found in {}", flake_dir.display()).into());
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

    // Resolve and fetch every reachable node so nested flakes can be evaluated.
    let nodes = resolve_flake_nodes(&lock, flake_dir)?;

    // Determine system
    let system = current_system();

    // Build eval expression
    let expr = build_flake_eval_expr(flake_dir, &nodes, &installable.attr_path, &system)?;

    eprintln!("evaluating .#{}...", installable.attr_path);

    // Evaluate `(expr).drvPath`
    let drv_path_expr = format!("({expr}).drvPath");
    let db =
        crate::pathinfo::PathInfoDb::open().map_err(|e| format!("opening pathinfo db: {e}"))?;
    let (drv_path_str, state) = crate::eval::evaluate_for_build(&drv_path_expr, &db)?;

    let drv_path_str = drv_path_str.trim_matches('"').to_string();
    let drv_path =
        nix_compat::store_path::StorePath::<String>::from_absolute_path(drv_path_str.as_bytes())
            .map_err(|e| format!("invalid derivation path '{drv_path_str}': {e}"))?;

    let known_paths_ref = state.known_paths.borrow();

    let result = crate::local_build::build_needed_with_options(
        &drv_path,
        &*known_paths_ref,
        &db,
        no_sandbox,
    )?;

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
    flake_dir: &Path,
) -> Result<String, Box<dyn std::error::Error>> {
    match locked.type_.as_str() {
        "github" | "gitlab" => {
            let url = resolve_tarball_url(locked).ok_or_else(|| {
                format!(
                    "cannot resolve tarball URL for input '{}' (type={})",
                    name, locked.type_
                )
            })?;

            let nar_hash = locked
                .nar_hash
                .as_deref()
                .ok_or_else(|| format!("input '{}' has no narHash", name))?;

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
        "tarball" => {
            let url = locked
                .url
                .as_deref()
                .ok_or_else(|| format!("tarball input '{}' has no url field", name))?;
            let nar_hash = locked
                .nar_hash
                .as_deref()
                .ok_or_else(|| format!("tarball input '{}' has no narHash", name))?;
            let store_path = compute_fod_store_path(name, nar_hash)?;
            if Path::new(&store_path).exists() {
                eprintln!("using cached input '{name}' at {store_path}");
                return Ok(store_path);
            }
            eprintln!("fetching input '{name}' from {url}...");
            fetch_and_extract_to_store(url, &store_path)?;
            verify_nar_hash(&store_path, nar_hash)?;
            Ok(store_path)
        }
        "path" => {
            let path = locked
                .path
                .as_deref()
                .ok_or_else(|| format!("path input '{}' has no path field", name))?;
            let path = Path::new(path);
            let resolved = if path.is_absolute() {
                path.to_path_buf()
            } else {
                flake_dir.join(path)
            };
            Ok(resolved.to_string_lossy().to_string())
        }
        "git" => {
            let url = locked
                .url
                .as_deref()
                .ok_or_else(|| format!("git input '{}' has no url field", name))?;
            let rev = locked
                .rev
                .as_deref()
                .ok_or_else(|| format!("git input '{}' has no rev field", name))?;
            let nar_hash = locked.nar_hash.as_deref();

            // Optimization: if the git URL matches a known forge, download
            // the archive tarball instead of cloning (much faster).
            if let Some(tarball_url) = git_url_to_forge_tarball(url, rev) {
                if let Some(nar_hash) = nar_hash {
                    let store_path = compute_fod_store_path(name, nar_hash)?;
                    if Path::new(&store_path).exists() {
                        eprintln!("using cached input '{name}' at {store_path}");
                        return Ok(store_path);
                    }
                    eprintln!("fetching input '{name}' from {tarball_url} (forge tarball)...");
                    fetch_and_extract_to_store(&tarball_url, &store_path)?;
                    verify_nar_hash(&store_path, nar_hash)?;
                    return Ok(store_path);
                }
            }

            // Fall back to git clone. Compute store path from narHash if available.
            let store_path = if let Some(nar_hash) = nar_hash {
                let sp = compute_fod_store_path(name, nar_hash)?;
                if Path::new(&sp).exists() {
                    eprintln!("using cached input '{name}' at {sp}");
                    return Ok(sp);
                }
                sp
            } else {
                // Without narHash, use a content-addressed temp path
                let hash_input = format!("git-{}-{}", url, rev);
                let hash = {
                    use sha2::{Digest, Sha256};
                    let h = Sha256::digest(hash_input.as_bytes());
                    data_encoding::HEXLOWER.encode(&h)[..32].to_string()
                };
                format!("/nix/store/{}-source", hash)
            };

            crate::fetchers::fetch_git(url, rev, &store_path, nar_hash)?;
            Ok(store_path)
        }
        other => Err(format!("unsupported input type '{}' for input '{}'", other, name).into()),
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

/// Try to convert a git URL to a forge archive tarball URL.
///
/// GitHub: `https://github.com/owner/repo.git` → `https://github.com/owner/repo/archive/<rev>.tar.gz`
/// GitLab: `https://gitlab.com/owner/repo.git` → `https://gitlab.com/owner/repo/-/archive/<rev>/repo-<rev>.tar.gz`
fn git_url_to_forge_tarball(url: &str, rev: &str) -> Option<String> {
    let url = url.strip_suffix(".git").unwrap_or(url);

    // GitHub
    if let Some(rest) = url.strip_prefix("https://github.com/") {
        // rest = "owner/repo"
        if rest.matches('/').count() == 1 && !rest.is_empty() {
            return Some(format!("https://github.com/{rest}/archive/{rev}.tar.gz"));
        }
    }

    // GitLab (any host with gitlab in the domain, or gitlab.com)
    // Pattern: https://<host>/<owner>/<repo>
    if url.contains("gitlab") {
        if let Some(after_scheme) = url.strip_prefix("https://") {
            // after_scheme = "gitlab.redox-os.org/redox-os/relibc"
            // Split into host and owner/repo path
            if let Some((host, owner_repo)) = after_scheme.split_once('/') {
                if let Some(repo_name) = owner_repo.rsplit('/').next() {
                    if !repo_name.is_empty() {
                        return Some(format!(
                            "https://{host}/{owner_repo}/-/archive/{rev}/{repo_name}-{rev}.tar.gz"
                        ));
                    }
                }
            }
        }
    }

    None
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
fn verify_nar_hash(store_path: &str, expected_sri: &str) -> Result<(), Box<dyn std::error::Error>> {
    use nix_compat::nixhash::{HashAlgo, NixHash};

    let expected = NixHash::from_str(expected_sri, Some(HashAlgo::Sha256))
        .map_err(|e| format!("invalid expected hash: {e}"))?;

    let (actual_hash_str, _size) = crate::local_build::nar_hash_path(Path::new(store_path))?;

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
        let resolved = resolve_attr_path("packages.x86_64-linux.hello", "x86_64-linux");
        assert_eq!(resolved, "packages.x86_64-linux.hello");
    }

    #[test]
    fn attr_path_redox_system() {
        let resolved = resolve_attr_path("ripgrep", "x86_64-unknown-redox");
        assert_eq!(resolved, "packages.\"x86_64-unknown-redox\".ripgrep");
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
                            [(
                                "hello".to_string(),
                                InputRef::Direct("hello-src".to_string()),
                            )]
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
                                (
                                    "nixpkgs".to_string(),
                                    InputRef::Direct("nixpkgs".to_string()),
                                ),
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

        // follows chain: root input "utils" → flake-utils, then its nixpkgs
        let resolved =
            resolve_follows(&lock, &["utils".to_string(), "nixpkgs".to_string()]).unwrap();
        assert_eq!(resolved, "nixpkgs");
    }

    // ── build_flake_eval_expr ──────────────────────────────────────────

    #[test]
    fn eval_expr_wires_flake_and_source_nodes() {
        let nodes = vec![
            ResolvedNode {
                name: "root".to_string(),
                store_path: "/tmp/myflake".to_string(),
                is_flake: true,
                inputs: [("hello-src".to_string(), "hello-src".to_string())]
                    .into_iter()
                    .collect(),
                locked: None,
                is_root: true,
            },
            ResolvedNode {
                name: "hello-src".to_string(),
                store_path: "/nix/store/abc-source".to_string(),
                is_flake: false,
                inputs: HashMap::new(),
                locked: None,
                is_root: false,
            },
        ];

        let expr =
            build_flake_eval_expr(Path::new("/tmp/myflake"), &nodes, "hello", "x86_64-linux")
                .unwrap();

        assert!(
            expr.contains("import /tmp/myflake/flake.nix"),
            "expr: {expr}"
        );
        assert!(
            expr.contains("\"hello-src\" = /nix/store/abc-source"),
            "expr: {expr}"
        );
        assert!(
            expr.contains("\"hello-src\" = __nodes.\"hello-src\""),
            "expr: {expr}"
        );
        assert!(expr.contains("__self = __info // {"), "expr: {expr}");
        assert!(
            expr.contains("__flake = __outputs // __self"),
            "expr: {expr}"
        );
        assert!(
            expr.contains("packages.\"x86_64-linux\".hello"),
            "expr: {expr}"
        );
    }

    #[test]
    fn eval_expr_qualified_attr() {
        let nodes = vec![ResolvedNode {
            name: "root".to_string(),
            store_path: "/tmp/f".to_string(),
            is_flake: true,
            inputs: HashMap::new(),
            locked: None,
            is_root: true,
        }];
        let expr = build_flake_eval_expr(
            Path::new("/tmp/f"),
            &nodes,
            "packages.x86_64-linux.hello",
            "x86_64-linux",
        )
        .unwrap();

        // Qualified attrs should be used as-is
        assert!(expr.contains("packages.x86_64-linux.hello"), "expr: {expr}");
    }

    fn path_locked(path: &Path) -> LockedRef {
        LockedRef {
            type_: "path".to_string(),
            owner: None,
            repo: None,
            rev: None,
            nar_hash: None,
            host: None,
            ref_: None,
            path: Some(path.to_string_lossy().to_string()),
            url: None,
            last_modified: None,
        }
    }

    fn path_node(path: &Path, flake: bool) -> LockNode {
        LockNode {
            locked: Some(path_locked(path)),
            original: None,
            inputs: None,
            flake: Some(flake),
        }
    }

    #[test]
    fn nested_flake_inputs_and_follows_evaluate() {
        let tmp = tempfile::tempdir().unwrap();
        let root_dir = tmp.path().join("root");
        let lib_dir = tmp.path().join("lib");
        let dep_dir = tmp.path().join("dep");
        let plain_dir = tmp.path().join("plain");
        for dir in [&root_dir, &lib_dir, &dep_dir, &plain_dir] {
            std::fs::create_dir(dir).unwrap();
        }

        std::fs::write(
            root_dir.join("flake.nix"),
            r#"
            {
              outputs = { self, lib, dep, plain }: {
                packages.x86_64-linux.answer =
                  lib.lib.greet dep.name + ":"
                  + builtins.baseNameOf lib.lib.selfPath + ":"
                  + builtins.readFile (plain + "/value.txt");
              };
            }
            "#,
        )
        .unwrap();
        std::fs::write(
            lib_dir.join("flake.nix"),
            r#"
            {
              outputs = { self, dep }: {
                lib.greet = name: "hello " + name + "/" + dep.name;
                lib.selfPath = self.outPath;
              };
            }
            "#,
        )
        .unwrap();
        std::fs::write(
            dep_dir.join("flake.nix"),
            r#"{ outputs = { self }: { name = "dep"; }; }"#,
        )
        .unwrap();
        std::fs::write(plain_dir.join("value.txt"), "plain").unwrap();

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
                                ("lib".to_string(), InputRef::Direct("lib".to_string())),
                                ("dep".to_string(), InputRef::Direct("dep".to_string())),
                                ("plain".to_string(), InputRef::Direct("plain".to_string())),
                            ]
                            .into_iter()
                            .collect(),
                        ),
                        flake: None,
                    },
                ),
                (
                    "lib".to_string(),
                    LockNode {
                        locked: Some(path_locked(&lib_dir)),
                        original: None,
                        inputs: Some(
                            [(
                                "dep".to_string(),
                                InputRef::Follows(vec!["dep".to_string()]),
                            )]
                            .into_iter()
                            .collect(),
                        ),
                        flake: None,
                    },
                ),
                ("dep".to_string(), path_node(&dep_dir, true)),
                ("plain".to_string(), path_node(&plain_dir, false)),
            ]
            .into_iter()
            .collect(),
        };

        let nodes = resolve_flake_nodes(&lock, &root_dir).unwrap();
        let expr = build_flake_eval_expr(
            &root_dir,
            &nodes,
            "packages.x86_64-linux.answer",
            "x86_64-linux",
        )
        .unwrap();
        let (value, _) = crate::eval::evaluate_with_state(&expr).unwrap();
        assert_eq!(value.trim_matches('"'), "hello dep/dep:lib:plain");
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
        let p1 = compute_fod_store_path("a", "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA=")
            .unwrap();
        let p2 = compute_fod_store_path("a", "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
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
        assert!(
            lock.nodes.len() > 10,
            "expected many nodes, got {}",
            lock.nodes.len()
        );

        // Root should have inputs
        let root_inputs = get_root_inputs(&lock).unwrap();
        assert!(
            root_inputs.contains_key("nixpkgs"),
            "should have nixpkgs input"
        );

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
    #[ignore = "fetches nix-redox's real flake inputs and evaluates the full flake"]
    fn real_flake_lists_package_systems() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .to_path_buf();
        let lock = parse_flake_lock(&root.join("flake.lock")).unwrap();
        let nodes = resolve_flake_nodes(&lock, &root).unwrap();
        let expr =
            build_flake_eval_expr(&root, &nodes, "outputs.packages", "x86_64-linux").unwrap();
        let (systems, _) =
            crate::eval::evaluate_with_state(&format!("builtins.attrNames ({expr})")).unwrap();
        assert!(systems.contains("x86_64-linux"), "systems: {systems}");
    }

    #[test]
    fn real_lock_reaches_adios_flake() {
        let lock_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("flake.lock");

        if !lock_path.exists() {
            return;
        }

        let lock = parse_flake_lock(&lock_path).unwrap();
        let root_inputs = get_root_inputs(&lock).unwrap();
        assert_eq!(
            root_inputs.get("adios-flake").map(String::as_str),
            Some("adios-flake")
        );

        let adios_flake = lock.nodes.get("adios-flake").unwrap();
        assert!(matches!(
            adios_flake.inputs.as_ref().unwrap().get("adios"),
            Some(InputRef::Direct(target)) if target == "adios"
        ));

        // Every reachable edge, including follows, resolves to a lock node.
        let reachable = reachable_nodes(&lock).unwrap();
        assert!(reachable.iter().any(|name| name == "adios-flake"));
        for name in &reachable {
            let node = lock.nodes.get(name).unwrap();
            for input in node.inputs.as_ref().into_iter().flatten().map(|(_, i)| i) {
                resolve_input_ref(&lock, input).unwrap();
            }
        }
    }

    #[test]
    fn real_lock_relibc_input() {
        let lock_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("flake.lock");

        if !lock_path.exists() {
            return;
        }

        let lock = parse_flake_lock(&lock_path).unwrap();
        let root_inputs = get_root_inputs(&lock).unwrap();

        // relibc-src has moved between GitLab and git lock entries; both must
        // keep resolving to the Redox relibc repository.
        if let Some(node_name) = root_inputs.get("relibc-src") {
            let node = lock.nodes.get(node_name).unwrap();
            let locked = node.locked.as_ref().unwrap();
            let url = match locked.type_.as_str() {
                "gitlab" => {
                    assert_eq!(locked.host.as_deref(), Some("gitlab.redox-os.org"));
                    resolve_tarball_url(locked).unwrap()
                }
                "git" => locked.url.clone().unwrap(),
                other => panic!("unexpected relibc-src lock type: {other}"),
            };
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

        let non_flake_count = lock.nodes.values().filter(|n| !n.is_flake()).count();

        // Should have many non-flake (source-only) inputs
        assert!(
            non_flake_count > 30,
            "expected >30 non-flake inputs, got {non_flake_count}"
        );
    }

    // ── git_url_to_forge_tarball ───────────────────────────────────

    #[test]
    fn forge_tarball_github() {
        let url = git_url_to_forge_tarball("https://github.com/NixOS/nixpkgs.git", "abc123");
        assert_eq!(
            url.unwrap(),
            "https://github.com/NixOS/nixpkgs/archive/abc123.tar.gz"
        );
    }

    #[test]
    fn forge_tarball_github_no_dot_git() {
        let url = git_url_to_forge_tarball("https://github.com/owner/repo", "def456");
        assert_eq!(
            url.unwrap(),
            "https://github.com/owner/repo/archive/def456.tar.gz"
        );
    }

    #[test]
    fn forge_tarball_gitlab() {
        let url =
            git_url_to_forge_tarball("https://gitlab.redox-os.org/redox-os/relibc.git", "abc123");
        assert_eq!(
            url.unwrap(),
            "https://gitlab.redox-os.org/redox-os/relibc/-/archive/abc123/relibc-abc123.tar.gz"
        );
    }

    #[test]
    fn forge_tarball_gitlab_default_host() {
        let url = git_url_to_forge_tarball("https://gitlab.com/user/project.git", "def456");
        assert_eq!(
            url.unwrap(),
            "https://gitlab.com/user/project/-/archive/def456/project-def456.tar.gz"
        );
    }

    #[test]
    fn forge_tarball_gitlab_no_dot_git() {
        let url = git_url_to_forge_tarball("https://gitlab.redox-os.org/redox-os/kernel", "aaa111");
        assert_eq!(
            url.unwrap(),
            "https://gitlab.redox-os.org/redox-os/kernel/-/archive/aaa111/kernel-aaa111.tar.gz"
        );
    }

    #[test]
    fn forge_tarball_not_a_forge() {
        let url = git_url_to_forge_tarball("https://git.example.com/foo/bar.git", "abc123");
        assert!(url.is_none());
    }

    #[test]
    fn forge_tarball_ssh_not_supported() {
        let url = git_url_to_forge_tarball("git@github.com:owner/repo.git", "abc123");
        // SSH URLs don't start with https:// so shouldn't match
        assert!(url.is_none());
    }
}
