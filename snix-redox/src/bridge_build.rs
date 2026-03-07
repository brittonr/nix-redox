//! Derivation-level bridge build protocol.
//!
//! Extends the rebuild bridge with per-derivation build requests,
//! allowing the guest to request builds of individual packages or
//! arbitrary Nix expressions from the host.
//!
//! Protocol (over virtio-fs shared directory):
//!
//! ```text
//! Guest                                     Host
//! ─────                                     ────
//! snix build --bridge --attr ripgrep
//!   ├─ writes build-*.json to requests/ ──→ build-bridge daemon
//!   │                                       ├─ nix build .#ripgrep
//!   │                                       ├─ exports to cache/
//!   │                                       └─ writes response
//!   ├─ polls responses/*.json ←────────────
//!   ├─ fetches from cache/ ←───────────────
//!   └─ registers in PathInfoDb
//! ```
//!
//! Request types:
//!   - `build-attr`: Build a flake attribute (`.#ripgrep`)
//!   - `build-drv`:  Build from a serialized derivation ATerm
//!
//! Response: output store paths + status

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::pathinfo::PathInfoDb;

const DEFAULT_SHARED_DIR: &str = "/scheme/shared";
const DEFAULT_TIMEOUT_POLLS: u64 = 300;

// ── Protocol Types ─────────────────────────────────────────────────────────

/// Request to build a derivation via the host bridge.
#[derive(Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DrvBuildRequest {
    /// Request type: "build-attr" or "build-drv"
    #[serde(rename = "type")]
    pub request_type: String,
    /// Unique request ID
    pub request_id: String,
    /// Flake attribute path (for build-attr)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attr: Option<String>,
    /// Derivation ATerm bytes (for build-drv)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drv_aterm: Option<String>,
    /// Derivation name (for build-drv)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drv_name: Option<String>,
    /// Expected output paths (for verification)
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub expected_outputs: BTreeMap<String, String>,
}

/// Response from the host after building a derivation.
#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DrvBuildResponse {
    /// "success" or "error"
    pub status: String,
    /// Matches the request ID
    #[serde(default)]
    pub request_id: String,
    /// Output name → store path mapping
    #[serde(default)]
    pub outputs: BTreeMap<String, String>,
    /// Error message (if status == "error")
    #[serde(default)]
    pub error: Option<String>,
    /// Build time in milliseconds
    #[serde(default)]
    pub build_time_ms: Option<u64>,
}

// ── Build by Flake Attribute ───────────────────────────────────────────────

/// Request the host to build a flake attribute (e.g., `.#ripgrep`).
///
/// The host evaluates and builds the same flake, so output paths match.
pub fn build_attr_via_bridge(
    attr: &str,
    shared_dir: Option<&str>,
    timeout_polls: Option<u64>,
) -> Result<DrvBuildResponse, Box<dyn std::error::Error>> {
    let shared = shared_dir.unwrap_or(DEFAULT_SHARED_DIR);
    let timeout = timeout_polls.unwrap_or(DEFAULT_TIMEOUT_POLLS);

    verify_shared_dir(shared)?;

    let request_id = generate_build_id(attr);
    let request = DrvBuildRequest {
        request_type: "build-attr".to_string(),
        request_id: request_id.clone(),
        attr: Some(attr.to_string()),
        drv_aterm: None,
        drv_name: None,
        expected_outputs: BTreeMap::new(),
    };

    send_and_wait(shared, &request_id, &request, timeout)
}

// ── Build by Derivation ATerm ──────────────────────────────────────────────

/// Request the host to build a derivation from its ATerm serialization.
///
/// The guest evaluates the expression locally, serializes the resulting
/// derivation, and sends it to the host for building.
pub fn build_drv_via_bridge(
    drv: &nix_compat::derivation::Derivation,
    drv_path: &nix_compat::store_path::StorePath<String>,
    shared_dir: Option<&str>,
    timeout_polls: Option<u64>,
) -> Result<DrvBuildResponse, Box<dyn std::error::Error>> {
    let shared = shared_dir.unwrap_or(DEFAULT_SHARED_DIR);
    let timeout = timeout_polls.unwrap_or(DEFAULT_TIMEOUT_POLLS);

    verify_shared_dir(shared)?;

    // Serialize derivation to ATerm
    let aterm_bytes = drv.to_aterm_bytes();
    let aterm_str = String::from_utf8(aterm_bytes)
        .map_err(|e| format!("derivation ATerm is not valid UTF-8: {e}"))?;

    // Derive a name from the drv path
    let name = drv_path
        .to_string()
        .strip_suffix(".drv")
        .unwrap_or(&drv_path.to_string())
        .to_string();

    // Collect expected output paths
    let expected_outputs: BTreeMap<String, String> = drv
        .outputs
        .iter()
        .filter_map(|(out_name, out)| {
            out.path
                .as_ref()
                .map(|p| (out_name.clone(), p.to_absolute_path()))
        })
        .collect();

    let request_id = generate_build_id(&name);
    let request = DrvBuildRequest {
        request_type: "build-drv".to_string(),
        request_id: request_id.clone(),
        attr: None,
        drv_aterm: Some(aterm_str),
        drv_name: Some(name),
        expected_outputs,
    };

    send_and_wait(shared, &request_id, &request, timeout)
}

// ── Fetch + Register ───────────────────────────────────────────────────────

/// After a successful bridge build, fetch outputs from the shared cache
/// and register them in the local PathInfoDb.
pub fn fetch_bridge_outputs(
    response: &DrvBuildResponse,
    shared_dir: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let shared = shared_dir.unwrap_or(DEFAULT_SHARED_DIR);
    let cache_path = format!("{shared}/cache");

    for (_name, store_path) in &response.outputs {
        if Path::new(store_path).exists() {
            continue;
        }

        eprintln!("  fetching {store_path}...");
        crate::local_cache::fetch_local(store_path, &cache_path)?;
    }

    Ok(())
}

// ── CLI Entry Point ────────────────────────────────────────────────────────

/// `snix build --bridge` — build via host bridge.
pub fn run(
    expr: Option<String>,
    file: Option<String>,
    attr: Option<String>,
    shared_dir: Option<String>,
    timeout: Option<u64>,
) -> Result<(), Box<dyn std::error::Error>> {
    let shared = shared_dir.as_deref();

    if let Some(ref attr) = attr {
        // Direct flake attribute build
        eprintln!("bridge: requesting build of .#{attr}...");
        let response = build_attr_via_bridge(attr, shared, timeout)?;
        handle_response(&response, shared)?;
        return Ok(());
    }

    // Evaluate expression locally, then send derivation to host
    let source = match (expr, file) {
        (Some(e), _) => e,
        (_, Some(f)) => std::fs::read_to_string(&f)?,
        _ => return Err("provide --expr, --file, or --attr".into()),
    };

    // Evaluate to get derivation path
    let drv_path_expr = format!("({source}).drvPath");
    let (drv_path_str, state) = crate::eval::evaluate_with_state(&drv_path_expr)?;

    let drv_path_str = drv_path_str.trim_matches('"').to_string();
    let drv_path =
        nix_compat::store_path::StorePath::<String>::from_absolute_path(drv_path_str.as_bytes())
            .map_err(|e| format!("invalid derivation path '{drv_path_str}': {e}"))?;

    let known_paths = state.known_paths.borrow();
    let drv = known_paths
        .get_drv_by_drvpath(&drv_path)
        .ok_or_else(|| format!("derivation not found: {drv_path}"))?;

    eprintln!(
        "bridge: requesting build of {} ({})",
        drv_path,
        drv.outputs.keys().cloned().collect::<Vec<_>>().join(", ")
    );

    let response = build_drv_via_bridge(drv, &drv_path, shared, timeout)?;
    handle_response(&response, shared)?;

    Ok(())
}

/// Process a build response: print outputs or error.
fn handle_response(
    response: &DrvBuildResponse,
    shared_dir: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    match response.status.as_str() {
        "success" => {
            if let Some(bt) = response.build_time_ms {
                eprintln!("bridge: build completed in {:.1}s", bt as f64 / 1000.0);
            }

            // Fetch outputs from shared cache
            fetch_bridge_outputs(response, shared_dir)?;

            // Print output paths
            for (name, path) in &response.outputs {
                if response.outputs.len() == 1 {
                    println!("{path}");
                } else {
                    println!("{name}: {path}");
                }
            }

            Ok(())
        }
        "error" => {
            let err = response
                .error
                .as_deref()
                .unwrap_or("unknown build error");
            Err(format!("bridge build failed: {err}").into())
        }
        other => Err(format!("unexpected bridge response status: {other}").into()),
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn verify_shared_dir(shared: &str) -> Result<(), Box<dyn std::error::Error>> {
    if !Path::new(shared).exists() {
        return Err(format!(
            "shared filesystem not available at {shared}\n\
             Is the VM started with --fs? (virtio-fs)"
        )
        .into());
    }
    Ok(())
}

fn generate_build_id(name: &str) -> String {
    // Sanitize name for use in filename
    let safe_name: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' })
        .collect();
    let pid = std::process::id();
    format!("build-{safe_name}-{pid}")
}

fn send_and_wait(
    shared: &str,
    request_id: &str,
    request: &DrvBuildRequest,
    timeout_polls: u64,
) -> Result<DrvBuildResponse, Box<dyn std::error::Error>> {
    // Ensure directories exist
    let req_dir = format!("{shared}/requests");
    let resp_dir = format!("{shared}/responses");
    fs::create_dir_all(&req_dir)?;
    fs::create_dir_all(&resp_dir)?;

    // Write request
    let req_path = format!("{req_dir}/{request_id}.json");
    let req_json = serde_json::to_string_pretty(request)?;
    fs::write(&req_path, &req_json)?;
    eprintln!("bridge: request written to {req_path}");

    // Poll for response
    let resp_path = format!("{resp_dir}/{request_id}.json");
    eprintln!("bridge: polling for response (timeout: {timeout_polls}s)...");

    let mut polls = 0u64;
    loop {
        polls += 1;

        if polls > timeout_polls {
            // Clean up request
            let _ = fs::remove_file(&req_path);
            return Err(format!(
                "bridge build timed out after {timeout_polls}s\n\
                 Is the build-bridge daemon running on the host?"
            )
            .into());
        }

        // Try to read response
        if let Ok(content) = fs::read_to_string(&resp_path) {
            if !content.is_empty() {
                if let Ok(response) = serde_json::from_str::<DrvBuildResponse>(&content) {
                    eprintln!("bridge: response received (after {polls} polls)");
                    // Clean up
                    let _ = fs::remove_file(&resp_path);
                    return Ok(response);
                }
            }
        }

        // Delay using FUSE I/O (std::thread::sleep unreliable on Redox)
        fuse_delay(shared, 3000);

        if polls % 10 == 0 {
            eprintln!("  [{polls}s] waiting for host build...");
        }
    }
}

/// Burn wall-clock time via FUSE I/O on the shared filesystem.
/// Each write+read cycle ≈ 0.3ms, so 3000 iterations ≈ 1 second.
fn fuse_delay(shared_dir: &str, iterations: u32) {
    let marker = format!("{shared_dir}/.build-poll-marker");
    for i in 0..iterations {
        let _ = fs::write(&marker, format!("{i}"));
        let _ = fs::read_to_string(&marker);
    }
    let _ = fs::remove_file(&marker);
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_build_attr_serializes() {
        let req = DrvBuildRequest {
            request_type: "build-attr".to_string(),
            request_id: "build-ripgrep-42".to_string(),
            attr: Some("ripgrep".to_string()),
            drv_aterm: None,
            drv_name: None,
            expected_outputs: BTreeMap::new(),
        };

        let json = serde_json::to_string_pretty(&req).unwrap();
        assert!(json.contains("\"type\": \"build-attr\""));
        assert!(json.contains("\"attr\": \"ripgrep\""));
        assert!(!json.contains("drvAterm")); // skipped when None
        assert!(!json.contains("drvName"));
    }

    #[test]
    fn request_build_drv_serializes() {
        let mut outputs = BTreeMap::new();
        outputs.insert(
            "out".to_string(),
            "/nix/store/abc123-hello".to_string(),
        );

        let req = DrvBuildRequest {
            request_type: "build-drv".to_string(),
            request_id: "build-hello-42".to_string(),
            attr: None,
            drv_aterm: Some("Derive(...)".to_string()),
            drv_name: Some("hello".to_string()),
            expected_outputs: outputs,
        };

        let json = serde_json::to_string_pretty(&req).unwrap();
        assert!(json.contains("\"type\": \"build-drv\""));
        assert!(json.contains("\"drvAterm\": \"Derive(...)\""));
        assert!(json.contains("\"drvName\": \"hello\""));
        assert!(json.contains("/nix/store/abc123-hello"));
    }

    #[test]
    fn response_success_parses() {
        let json = r#"{
            "status": "success",
            "requestId": "build-ripgrep-42",
            "outputs": {"out": "/nix/store/xyz-ripgrep-14.0"},
            "buildTimeMs": 3500
        }"#;

        let resp: DrvBuildResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.status, "success");
        assert_eq!(resp.request_id, "build-ripgrep-42");
        assert_eq!(
            resp.outputs.get("out").unwrap(),
            "/nix/store/xyz-ripgrep-14.0"
        );
        assert_eq!(resp.build_time_ms, Some(3500));
        assert!(resp.error.is_none());
    }

    #[test]
    fn response_error_parses() {
        let json = r#"{
            "status": "error",
            "requestId": "build-nope-42",
            "error": "attribute 'nope' not found"
        }"#;

        let resp: DrvBuildResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.status, "error");
        assert!(resp.outputs.is_empty());
        assert_eq!(
            resp.error.unwrap(),
            "attribute 'nope' not found"
        );
    }

    #[test]
    fn response_minimal_parses() {
        let json = r#"{"status": "success"}"#;
        let resp: DrvBuildResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.status, "success");
        assert!(resp.outputs.is_empty());
        assert!(resp.error.is_none());
    }

    #[test]
    fn response_multiple_outputs_parses() {
        let json = r#"{
            "status": "success",
            "requestId": "build-multi-42",
            "outputs": {
                "out": "/nix/store/aaa-multi",
                "dev": "/nix/store/bbb-multi-dev",
                "lib": "/nix/store/ccc-multi-lib"
            }
        }"#;

        let resp: DrvBuildResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.outputs.len(), 3);
        assert!(resp.outputs.contains_key("out"));
        assert!(resp.outputs.contains_key("dev"));
        assert!(resp.outputs.contains_key("lib"));
    }

    #[test]
    fn generate_build_id_sanitizes() {
        let id = generate_build_id("hello-world");
        assert!(id.starts_with("build-hello-world-"));

        let id = generate_build_id("pkg/with spaces");
        assert!(!id.contains('/'));
        assert!(!id.contains(' '));
    }

    #[test]
    fn request_roundtrip_build_attr() {
        let req = DrvBuildRequest {
            request_type: "build-attr".to_string(),
            request_id: "build-test-1".to_string(),
            attr: Some("snix".to_string()),
            drv_aterm: None,
            drv_name: None,
            expected_outputs: BTreeMap::new(),
        };

        let json = serde_json::to_string(&req).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["type"], "build-attr");
        assert_eq!(parsed["requestId"], "build-test-1");
        assert_eq!(parsed["attr"], "snix");
    }

    #[test]
    fn evaluate_and_build_drv_request() {
        // Evaluate a derivation, serialize it, and verify request format
        let (drv_path_str, state) = crate::eval::evaluate_with_state(
            r#"(derivation { name = "bridge-test"; builder = "/bin/sh"; system = "x86_64-linux"; }).drvPath"#,
        )
        .unwrap();

        let drv_path_str = drv_path_str.trim_matches('"');
        let drv_path = nix_compat::store_path::StorePath::<String>::from_absolute_path(
            drv_path_str.as_bytes(),
        )
        .unwrap();

        let known_paths = state.known_paths.borrow();
        let drv = known_paths.get_drv_by_drvpath(&drv_path).unwrap();

        // Serialize to ATerm
        let aterm = drv.to_aterm_bytes();
        let aterm_str = String::from_utf8(aterm).unwrap();
        assert!(aterm_str.starts_with("Derive("));

        // Build the request
        let expected_outputs: BTreeMap<String, String> = drv
            .outputs
            .iter()
            .filter_map(|(name, out)| {
                out.path.as_ref().map(|p| (name.clone(), p.to_absolute_path()))
            })
            .collect();

        assert!(expected_outputs.contains_key("out"));

        let req = DrvBuildRequest {
            request_type: "build-drv".to_string(),
            request_id: "build-bridge-test-1".to_string(),
            attr: None,
            drv_aterm: Some(aterm_str.clone()),
            drv_name: Some("bridge-test".to_string()),
            expected_outputs,
        };

        let json = serde_json::to_string_pretty(&req).unwrap();
        assert!(json.contains("Derive("));
        assert!(json.contains("bridge-test"));
    }
}
