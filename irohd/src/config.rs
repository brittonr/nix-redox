//! Configuration and node identity management.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

/// Peer entry: human name → node ID (hex-encoded public key).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerEntry {
    pub name: String,
    pub node_id: String,
}

/// Runtime configuration for irohd.
#[derive(Debug, Clone)]
pub struct IrohConfig {
    /// Path to the node secret key file.
    pub key_path: PathBuf,
    /// Path to the peers config file.
    pub peers_path: PathBuf,
    /// Pre-loaded peer table (name → node_id hex).
    pub peers: HashMap<String, String>,
    /// Raw secret key bytes (32 bytes), loaded or generated.
    pub secret_key: [u8; 32],
}

impl IrohConfig {
    /// Load config from standard paths, generating a key if needed.
    pub fn load() -> Result<Self, Box<dyn std::error::Error>> {
        let key_path = PathBuf::from("/etc/iroh/node.key");
        let peers_path = PathBuf::from("/etc/iroh/peers.json");

        // Load or generate secret key.
        let secret_key = Self::load_or_generate_key(&key_path)?;

        // Load peers (empty map if file doesn't exist).
        let peers = Self::load_peers(&peers_path);

        Ok(Self {
            key_path,
            peers_path,
            peers,
            secret_key,
        })
    }

    fn load_or_generate_key(
        path: &std::path::Path,
    ) -> Result<[u8; 32], Box<dyn std::error::Error>> {
        if path.exists() {
            let data = std::fs::read(path)?;
            if data.len() < 32 {
                return Err(format!(
                    "key file too short: {} bytes (need 32)",
                    data.len()
                )
                .into());
            }
            let mut key = [0u8; 32];
            key.copy_from_slice(&data[..32]);
            eprintln!("irohd: loaded node key from {}", path.display());
            Ok(key)
        } else {
            // Generate a new key using OS randomness.
            let mut key = [0u8; 32];
            getrandom(&mut key)?;
            // Ensure parent dir exists.
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::write(path, &key)?;
            eprintln!("irohd: generated new node key at {}", path.display());
            Ok(key)
        }
    }

    fn load_peers(path: &std::path::Path) -> HashMap<String, String> {
        let data = match std::fs::read_to_string(path) {
            Ok(d) => d,
            Err(_) => {
                eprintln!(
                    "irohd: no peers file at {}, starting with empty peer table",
                    path.display()
                );
                return HashMap::new();
            }
        };

        // Format: {"peers": [{"name": "alice", "node_id": "abc..."}]}
        // Or simple: {"alice": "abc...", "bob": "def..."}
        // Try simple format first.
        match serde_json::from_str::<HashMap<String, String>>(&data) {
            Ok(map) => {
                eprintln!("irohd: loaded {} peers from {}", map.len(), path.display());
                map
            }
            Err(_) => {
                // Try structured format.
                #[derive(Deserialize)]
                struct PeersFile {
                    peers: Vec<PeerEntry>,
                }
                match serde_json::from_str::<PeersFile>(&data) {
                    Ok(pf) => {
                        let map: HashMap<String, String> = pf
                            .peers
                            .into_iter()
                            .map(|p| (p.name, p.node_id))
                            .collect();
                        eprintln!(
                            "irohd: loaded {} peers from {}",
                            map.len(),
                            path.display()
                        );
                        map
                    }
                    Err(e) => {
                        eprintln!("irohd: failed to parse {}: {e}", path.display());
                        HashMap::new()
                    }
                }
            }
        }
    }
}

/// Fill buffer with random bytes (Redox-compatible).
fn getrandom(buf: &mut [u8]) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Read;
    let mut f = std::fs::File::open("/scheme/rand")?;
    f.read_exact(buf)?;
    Ok(())
}
