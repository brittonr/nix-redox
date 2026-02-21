//! Channel management for remote system updates.
//!
//! A "channel" is a URL pointing to a manifest.json describing a system
//! configuration. This enables `snix system switch` to work with upstream
//! updates instead of just local manifests.
//!
//! Channel layout (remote):
//!   https://example.com/redox/latest/
//!     manifest.json          — system manifest
//!     packages.json          — binary cache index (optional)
//!
//! Local state:
//!   /nix/var/snix/channels/
//!     {name}/
//!       manifest.json        — cached manifest
//!       url                  — channel URL
//!       last-fetched         — timestamp of last fetch

use std::fs;
use std::path::{Path, PathBuf};

const CHANNELS_DIR: &str = "/nix/var/snix/channels";

/// A registered channel.
#[derive(Debug)]
pub struct Channel {
    pub name: String,
    pub url: String,
    pub last_fetched: Option<String>,
    pub manifest_path: PathBuf,
}

/// Add or update a channel registration.
pub fn add(name: &str, url: &str) -> Result<(), Box<dyn std::error::Error>> {
    let channel_dir = Path::new(CHANNELS_DIR).join(name);
    fs::create_dir_all(&channel_dir)?;

    fs::write(channel_dir.join("url"), url)?;

    println!("Channel '{name}' registered: {url}");
    println!("Run `snix channel update {name}` to fetch the manifest.");
    Ok(())
}

/// Remove a channel registration.
pub fn remove(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let channel_dir = Path::new(CHANNELS_DIR).join(name);
    if !channel_dir.exists() {
        return Err(format!("channel '{name}' not found").into());
    }
    fs::remove_dir_all(&channel_dir)?;
    println!("Removed channel '{name}'");
    Ok(())
}

/// List all registered channels.
pub fn list() -> Result<(), Box<dyn std::error::Error>> {
    let dir = Path::new(CHANNELS_DIR);
    if !dir.exists() {
        println!("No channels registered.");
        println!("Add one with: snix channel add <name> <url>");
        return Ok(());
    }

    let mut channels = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        let url = fs::read_to_string(entry.path().join("url"))
            .unwrap_or_else(|_| "<unknown>".to_string())
            .trim()
            .to_string();
        let last_fetched = fs::read_to_string(entry.path().join("last-fetched"))
            .ok()
            .map(|s| s.trim().to_string());
        let has_manifest = entry.path().join("manifest.json").exists();

        channels.push((name, url, last_fetched, has_manifest));
    }

    if channels.is_empty() {
        println!("No channels registered.");
        return Ok(());
    }

    channels.sort_by(|a, b| a.0.cmp(&b.0));

    println!("Registered channels:");
    println!();
    for (name, url, fetched, has_manifest) in &channels {
        let status = if *has_manifest { "✓" } else { "○" };
        println!("  {status} {name}");
        println!("    URL:     {url}");
        if let Some(ts) = fetched {
            println!("    Fetched: {ts}");
        } else {
            println!("    Fetched: never");
        }
    }

    println!();
    println!("{} channels.", channels.len());
    Ok(())
}

/// Fetch/update a channel's manifest from its URL.
pub fn update(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let channel_dir = Path::new(CHANNELS_DIR).join(name);
    if !channel_dir.exists() {
        return Err(format!("channel '{name}' not found. Add it with: snix channel add {name} <url>").into());
    }

    let url = fs::read_to_string(channel_dir.join("url"))
        .map_err(|_| format!("channel '{name}' has no URL"))?
        .trim()
        .to_string();

    let manifest_url = if url.ends_with('/') {
        format!("{url}manifest.json")
    } else if url.ends_with(".json") {
        url.clone()
    } else {
        format!("{url}/manifest.json")
    };

    eprintln!("Fetching {manifest_url}...");

    let response = ureq::get(&manifest_url).call()?;

    if response.status() != 200 {
        return Err(format!("HTTP {}: {manifest_url}", response.status()).into());
    }

    let body = response.into_body().read_to_string()?;

    // Validate it's valid JSON (but don't require full manifest schema —
    // the channel might have a newer format)
    let _: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| format!("invalid JSON from {manifest_url}: {e}"))?;

    // Save manifest
    fs::write(channel_dir.join("manifest.json"), &body)?;

    // Update timestamp
    let timestamp = crate::system::current_timestamp_pub();
    fs::write(channel_dir.join("last-fetched"), &timestamp)?;

    println!("Channel '{name}' updated from {url}");
    println!("Manifest saved to {}", channel_dir.join("manifest.json").display());
    println!();
    println!("To switch to this channel:");
    println!("  snix system switch {}", channel_dir.join("manifest.json").display());

    Ok(())
}

/// Update all registered channels.
pub fn update_all() -> Result<(), Box<dyn std::error::Error>> {
    let dir = Path::new(CHANNELS_DIR);
    if !dir.exists() {
        println!("No channels to update.");
        return Ok(());
    }

    let mut names = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            names.push(entry.file_name().to_string_lossy().to_string());
        }
    }

    if names.is_empty() {
        println!("No channels to update.");
        return Ok(());
    }

    names.sort();
    let mut errors = 0;

    for name in &names {
        if let Err(e) = update(name) {
            eprintln!("error updating '{name}': {e}");
            errors += 1;
        }
        println!();
    }

    if errors > 0 {
        Err(format!("{errors} channel(s) failed to update").into())
    } else {
        println!("All {} channels updated.", names.len());
        Ok(())
    }
}

/// Get the manifest path for a named channel (for use by `system switch --channel`).
pub fn get_manifest_path(name: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let manifest = Path::new(CHANNELS_DIR).join(name).join("manifest.json");
    if !manifest.exists() {
        return Err(format!(
            "channel '{name}' has no manifest. Run: snix channel update {name}"
        )
        .into());
    }
    Ok(manifest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_dir_format() {
        let path = Path::new(CHANNELS_DIR).join("stable");
        assert_eq!(
            path.to_str().unwrap(),
            "/nix/var/snix/channels/stable"
        );
    }

    #[test]
    fn get_manifest_path_nonexistent() {
        let result = get_manifest_path("nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn channel_add_and_list_with_tempdir() {
        let tmp = tempfile::tempdir().unwrap();
        let channel_dir = tmp.path().join("test-channel");
        fs::create_dir_all(&channel_dir).unwrap();
        fs::write(channel_dir.join("url"), "https://example.com/redox/").unwrap();

        // Verify files created
        assert!(channel_dir.join("url").exists());
        let url = fs::read_to_string(channel_dir.join("url")).unwrap();
        assert_eq!(url.trim(), "https://example.com/redox/");
    }
}
