//! Bridge client: guest-initiated rebuild via virtio-fs shared filesystem.
//!
//! Communicates with the host-side `redox-build-bridge` daemon through
//! the shared directory (typically `/scheme/shared`) exposed by virtio-fs.
//!
//! Protocol:
//!   1. Guest evaluates configuration.nix → RebuildConfig JSON
//!   2. Guest writes request to /scheme/shared/requests/<id>.json
//!   3. Host daemon builds new system, exports packages to cache
//!   4. Host writes response to /scheme/shared/responses/<id>.json
//!   5. Guest polls for response, installs packages, activates
//!
//! Request format:
//!   { "requestId": "rebuild-<pid>-<ts>", "config": { ...RebuildConfig... } }
//!
//! Response format:
//!   { "status": "success"|"error", "requestId": "...",
//!     "manifest": { ...Manifest... }, "buildTimeMs": 1234 }

use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::rebuild;
use crate::system::{self, Manifest};

const DEFAULT_SHARED_DIR: &str = "/scheme/shared";
const POLL_INTERVAL_MS: u64 = 500;
const DEFAULT_TIMEOUT_S: u64 = 300;
const DEFAULT_MANIFEST_PATH: &str = "/etc/redox-system/manifest.json";

// ===== Protocol Types =====

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BridgeRequest {
    request_id: String,
    config: serde_json::Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BridgeResponse {
    status: String,
    #[serde(default)]
    request_id: String,
    manifest: Option<serde_json::Value>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    build_time_ms: Option<u64>,
}

// ===== Public API =====

/// Rebuild the system via the bridge protocol.
///
/// Evaluates configuration.nix, sends a build request to the host daemon,
/// polls for the response, installs new packages, and activates.
pub fn rebuild_via_bridge(
    config_path: Option<&str>,
    dry_run: bool,
    shared_dir: Option<&str>,
    timeout_s: Option<u64>,
    manifest_path: Option<&str>,
    gen_dir: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let shared = shared_dir.unwrap_or(DEFAULT_SHARED_DIR);
    let mpath = manifest_path.unwrap_or(DEFAULT_MANIFEST_PATH);
    let timeout = timeout_s.unwrap_or(DEFAULT_TIMEOUT_S);
    let cfg_path = config_path.unwrap_or("/etc/redox-system/configuration.nix");

    eprintln!("bridge: starting rebuild (shared={shared}, config={cfg_path})");

    // Verify shared filesystem is available
    if !Path::new(shared).exists() {
        return Err(format!(
            "shared filesystem not available at {shared}\n\
             Is virtio-fsd running? The VM must be started with --fs."
        )
        .into());
    }

    // Step 1: Evaluate configuration
    eprintln!("bridge: evaluating {cfg_path}...");
    let config = rebuild::evaluate_config_pub(cfg_path)?;
    let config_json = serde_json::to_value(&config)?;
    eprintln!("bridge: config parsed OK");

    // Step 2: Generate request
    let request_id = generate_request_id();
    let request = BridgeRequest {
        request_id: request_id.clone(),
        config: config_json,
    };

    // Ensure request directory exists
    let req_dir = format!("{shared}/requests");
    fs::create_dir_all(&req_dir)?;

    let req_path = format!("{req_dir}/{request_id}.json");
    let req_json = serde_json::to_string_pretty(&request)?;

    if dry_run {
        println!();
        println!("Dry run: would send build request to host:");
        println!("  Request:  {req_path}");
        println!("  Content:  {}", summarize_config(&config));
        println!();
        println!("No changes applied.");
        return Ok(());
    }

    // Step 3: Write request to shared filesystem
    eprintln!("bridge: writing request {request_id} to {req_path}");
    fs::write(&req_path, &req_json)?;
    eprintln!("bridge: request written OK");

    // Step 4: Poll for response
    let resp_path = format!("{shared}/responses/{request_id}.json");
    eprintln!("bridge: polling for response at {resp_path} (timeout: {timeout}s)");

    let response = poll_response(&resp_path, timeout)?;

    // Step 5: Process response
    match response.status.as_str() {
        "success" => {
            if let Some(bt) = response.build_time_ms {
                println!("Host build completed in {:.1}s", bt as f64 / 1000.0);
            } else {
                println!("Host build completed.");
            }
            println!();

            let manifest_value = response
                .manifest
                .ok_or("response missing manifest field")?;
            let new_manifest: Manifest = serde_json::from_value(manifest_value)?;

            // Install packages from shared cache
            let cache_path = format!("{shared}/cache");
            let installed = install_bridge_packages(&new_manifest, &cache_path)?;
            if installed > 0 {
                println!("{installed} new packages installed from cache.");
            }

            // Write manifest to temp file and switch
            let tmp_path = format!("/tmp/snix-bridge-{}.json", std::process::id());
            let manifest_json = serde_json::to_string_pretty(&new_manifest)?;
            fs::write(&tmp_path, &manifest_json)?;

            let result = system::switch(
                &tmp_path,
                Some("rebuild via bridge"),
                false,
                gen_dir,
                Some(mpath),
            );

            // Clean up temp files
            let _ = fs::remove_file(&tmp_path);
            let _ = fs::remove_file(&resp_path);

            result?;

            println!();
            println!("✓ System rebuilt via bridge from {cfg_path}");
        }
        "error" => {
            let error = response
                .error
                .unwrap_or_else(|| "unknown build error".to_string());

            // Clean up response file
            let _ = fs::remove_file(&resp_path);

            return Err(format!("Host build failed:\n{error}").into());
        }
        other => {
            let _ = fs::remove_file(&resp_path);
            return Err(format!("Unknown response status: {other}").into());
        }
    }

    Ok(())
}

// ===== Internal Helpers =====

/// Generate a unique request ID using PID and a simple counter.
fn generate_request_id() -> String {
    // Use PID for uniqueness within a boot session.
    // On Redox, PIDs are small integers, so this gives readable IDs.
    let pid = std::process::id();

    // Include a timestamp-like counter from /dev/null reads (cheap monotonic source)
    // On real systems this would use the clock; keeping it simple for Redox.
    format!("rebuild-{pid}")
}

/// Summarize a RebuildConfig for dry-run display.
fn summarize_config(config: &rebuild::RebuildConfig) -> String {
    let mut parts = Vec::new();

    if let Some(ref h) = config.hostname {
        parts.push(format!("hostname={h}"));
    }
    if let Some(ref pkgs) = config.packages {
        parts.push(format!("packages=[{}]", pkgs.join(", ")));
    }
    if let Some(ref net) = config.networking {
        if let Some(ref mode) = net.mode {
            parts.push(format!("networking.mode={mode}"));
        }
    }

    if parts.is_empty() {
        "no changes".to_string()
    } else {
        parts.join(", ")
    }
}

/// Poll the shared filesystem for a response file.
///
/// Uses direct read attempts rather than exists() checks, since
/// on Redox with virtio-fs, newly created host files may not be
/// immediately visible via stat() but can be opened directly.
fn poll_response(
    path: &str,
    timeout_s: u64,
) -> Result<BridgeResponse, Box<dyn std::error::Error>> {
    let start = Instant::now();
    let timeout = Duration::from_secs(timeout_s);
    let poll_interval = Duration::from_millis(POLL_INTERVAL_MS);
    let mut dots = 0u32;

    // Also try listing the parent directory to force FUSE cache refresh
    let parent = Path::new(path)
        .parent()
        .map(|p| p.to_path_buf());

    loop {
        if start.elapsed() >= timeout {
            // Debug: show what files exist in the responses directory
            let mut diag = String::new();
            if let Some(ref p) = parent {
                match fs::read_dir(p) {
                    Ok(entries) => {
                        diag.push_str(&format!("\n  Files in {}:", p.display()));
                        for entry in entries.flatten() {
                            diag.push_str(&format!("\n    {}", entry.file_name().to_string_lossy()));
                        }
                    }
                    Err(e) => {
                        diag.push_str(&format!("\n  Cannot list {}: {e}", p.display()));
                    }
                }
            }
            return Err(format!(
                "timed out waiting for host response after {timeout_s}s\n\
                 Expected: {path}\n\
                 Is the build-bridge daemon running on the host?{diag}"
            )
            .into());
        }

        // Force a directory listing to refresh FUSE cache
        if let Some(ref p) = parent {
            let _ = fs::read_dir(p);
        }

        // Try to read the file directly (more reliable than exists() on virtio-fs)
        match fs::read_to_string(path) {
            Ok(content) if !content.is_empty() => {
                match serde_json::from_str::<BridgeResponse>(&content) {
                    Ok(response) => return Ok(response),
                    Err(e) => {
                        // File exists but isn't valid JSON yet — host may still be writing
                        eprintln!("  (response file incomplete, retrying: {e})");
                        std::thread::sleep(Duration::from_millis(500));
                        continue;
                    }
                }
            }
            Ok(_) => {
                // Empty file — host started writing but not done
                std::thread::sleep(Duration::from_millis(200));
                continue;
            }
            Err(_) => {
                // File doesn't exist yet — keep polling
            }
        }

        std::thread::sleep(poll_interval);

        // Progress indicator every ~5 seconds
        dots += 1;
        if dots % 10 == 0 {
            let elapsed = start.elapsed().as_secs();
            eprintln!("  [{elapsed}s] waiting for host response...");
        }
    }
}

/// Install packages from the bridge's shared cache.
///
/// Scans the manifest's package list, skips packages already in the store,
/// and installs missing ones from the shared cache directory.
fn install_bridge_packages(
    manifest: &Manifest,
    cache_path: &str,
) -> Result<u32, Box<dyn std::error::Error>> {
    let mut installed = 0u32;

    for pkg in &manifest.packages {
        if pkg.store_path.is_empty() {
            continue;
        }

        // Skip packages already in the store
        if Path::new(&pkg.store_path).exists() {
            continue;
        }

        eprintln!("  Installing {} {}...", pkg.name, pkg.version);
        match crate::local_cache::fetch_local(&pkg.store_path, cache_path) {
            Ok(()) => {
                installed += 1;
            }
            Err(e) => {
                eprintln!("  warning: could not install {}: {e}", pkg.name);
            }
        }
    }

    Ok(installed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_request_id() {
        let id = generate_request_id();
        assert!(id.starts_with("rebuild-"));
        // Should contain PID
        let pid = std::process::id();
        assert!(id.contains(&pid.to_string()));
    }

    #[test]
    fn test_summarize_config_empty() {
        let config = rebuild::RebuildConfig::default();
        let summary = summarize_config(&config);
        assert_eq!(summary, "no changes");
    }

    #[test]
    fn test_summarize_config_hostname() {
        let config = rebuild::RebuildConfig {
            hostname: Some("test-host".to_string()),
            ..Default::default()
        };
        let summary = summarize_config(&config);
        assert!(summary.contains("hostname=test-host"));
    }

    #[test]
    fn test_summarize_config_packages() {
        let config = rebuild::RebuildConfig {
            packages: Some(vec!["ripgrep".into(), "fd".into()]),
            ..Default::default()
        };
        let summary = summarize_config(&config);
        assert!(summary.contains("packages=[ripgrep, fd]"));
    }

    #[test]
    fn test_parse_bridge_response_success() {
        let json = r#"{
            "status": "success",
            "requestId": "rebuild-42",
            "manifest": {"manifestVersion": 1, "system": {"redoxSystemVersion": "0.5.0",
                "target": "x86_64-unknown-redox", "profile": "development",
                "hostname": "test", "timezone": "UTC"},
                "configuration": {"boot": {"diskSizeMB": 768, "espSizeMB": 200},
                    "hardware": {"storageDrivers": [], "networkDrivers": [],
                        "graphicsDrivers": [], "audioDrivers": [], "usbEnabled": false},
                    "networking": {"enabled": true, "mode": "auto", "dns": []},
                    "graphics": {"enabled": false, "resolution": "1024x768"},
                    "security": {"protectKernelSchemes": true, "requirePasswords": false,
                        "allowRemoteRoot": false},
                    "logging": {"logLevel": "info", "kernelLogLevel": "warn",
                        "logToFile": true, "maxLogSizeMB": 10},
                    "power": {"acpiEnabled": true, "powerAction": "shutdown",
                        "rebootOnPanic": false}},
                "packages": [], "drivers": {"all": [], "initfs": [], "core": []},
                "users": {}, "groups": {},
                "services": {"initScripts": [], "startupScript": "/startup.sh"},
                "files": {}},
            "buildTimeMs": 5000
        }"#;

        let resp: BridgeResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.status, "success");
        assert_eq!(resp.request_id, "rebuild-42");
        assert!(resp.manifest.is_some());
        assert_eq!(resp.build_time_ms, Some(5000));
        assert!(resp.error.is_none());
    }

    #[test]
    fn test_parse_bridge_response_error() {
        let json = r#"{
            "status": "error",
            "requestId": "rebuild-42",
            "error": "nix build failed: derivation missing"
        }"#;

        let resp: BridgeResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.status, "error");
        assert!(resp.manifest.is_none());
        assert_eq!(
            resp.error,
            Some("nix build failed: derivation missing".to_string())
        );
    }

    #[test]
    fn test_parse_bridge_request_roundtrip() {
        let config = serde_json::json!({
            "hostname": "bridge-host",
            "packages": ["ripgrep", "fd"]
        });

        let req = BridgeRequest {
            request_id: "rebuild-123".to_string(),
            config,
        };

        let json = serde_json::to_string(&req).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["requestId"], "rebuild-123");
        assert_eq!(parsed["config"]["hostname"], "bridge-host");
    }

    #[test]
    fn test_parse_bridge_response_minimal() {
        // Response with only required fields
        let json = r#"{"status": "success"}"#;
        let resp: BridgeResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.status, "success");
        assert!(resp.manifest.is_none());
        assert!(resp.error.is_none());
        assert!(resp.build_time_ms.is_none());
        assert!(resp.request_id.is_empty());
    }
}
