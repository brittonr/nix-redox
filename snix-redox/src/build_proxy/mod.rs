//! Per-path filesystem proxy for build sandboxing.
//!
//! Interposes on the `file:` scheme in a builder's namespace, restricting
//! access to an allow-list of paths derived from the derivation's declared
//! inputs. The proxy registers itself as `file` in a child namespace via
//! `register_scheme_to_ns`, so all file operations from the builder
//! transparently route through the proxy.
//!
//! ## Architecture
//!
//! ```text
//!   snix (parent)                    builder (child)
//!   ─────────────                    ───────────────
//!   1. mkns([memory,pipe,rand,...])
//!      → child_ns_fd (no file:)
//!   2. Socket::create()
//!      register_scheme_to_ns(
//!        child_ns_fd, "file", ...)
//!   3. spawn proxy thread
//!   4. fork → setns(child_ns_fd)     exec(builder)
//!      │                              open("file:/nix/store/dep/...")
//!      │                                  ↓
//!      ├── proxy event loop ←─────── scheme request arrives
//!      │   check allow-list
//!      │   open real file (parent ns)
//!      │   return data ──────────────→ builder gets bytes
//!      │
//!   5. builder exits
//!   6. proxy.shutdown()
//! ```
//!
//! ## Platform gating
//!
//! The proxy scheme handler and lifecycle code compile only on Redox
//! (`#[cfg(target_os = "redox")]`). The `AllowList` and path matching
//! logic is platform-independent for host testing.

pub mod allow_list;

#[cfg(target_os = "redox")]
pub mod handler;

#[cfg(target_os = "redox")]
pub mod lifecycle;

// Re-export core types used by local_build.rs.
pub use allow_list::{AllowList, Permission, build_allow_list};

#[cfg(target_os = "redox")]
pub use lifecycle::BuildFsProxy;

/// Stub for non-Redox platforms. Does nothing — builds run unsandboxed.
#[cfg(not(target_os = "redox"))]
pub struct BuildFsProxy;

#[cfg(not(target_os = "redox"))]
impl BuildFsProxy {
    /// No-op on non-Redox. Returns Ok immediately.
    pub fn start(
        _child_ns_fd: usize,
        _allow_list: AllowList,
    ) -> Result<Self, BuildFsProxyError> {
        Ok(Self)
    }

    /// No-op on non-Redox.
    pub fn shutdown(self) {}
}

/// Errors from proxy setup.
#[derive(Debug)]
pub enum BuildFsProxyError {
    /// The kernel doesn't support the required syscalls.
    Unavailable,
    /// Socket creation or scheme registration failed.
    SetupFailed(String),
    /// The proxy thread panicked.
    ThreadPanicked,
}

impl std::fmt::Display for BuildFsProxyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(f, "build filesystem proxy unavailable on this kernel"),
            Self::SetupFailed(msg) => write!(f, "proxy setup failed: {msg}"),
            Self::ThreadPanicked => write!(f, "proxy thread panicked"),
        }
    }
}

impl std::error::Error for BuildFsProxyError {}
