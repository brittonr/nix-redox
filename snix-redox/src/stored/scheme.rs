//! Redox scheme protocol implementation for `stored`.
//!
//! This module is only compiled on Redox (`#[cfg(target_os = "redox")]`).
//! It bridges the Redox kernel's scheme request protocol to the core
//! store daemon logic (handle table, path resolution, lazy extraction).
//!
//! The scheme request loop:
//!   1. Kernel sends `Packet` structs to the scheme socket
//!   2. We dispatch by syscall number (SYS_OPEN, SYS_READ, etc.)
//!   3. Each handler delegates to the core logic in `handles`, `resolve`, `lazy`
//!   4. We write the response packet back to the kernel
//!
//! Reference: `virtio-fsd/src/scheme.rs` for the established pattern.

// This entire module is Redox-only.
// On other platforms, it's excluded by `#[cfg(target_os = "redox")]` in mod.rs.

use super::{StoreDaemon, StoredConfig};

/// Run the store scheme daemon (blocking).
///
/// Registers the `store` scheme with the kernel, then enters the
/// main event loop processing scheme requests.
pub fn run_daemon(config: StoredConfig) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("stored: initializing (cache={}, store={})", config.cache_path, config.store_dir);

    let _daemon = StoreDaemon::new(config)?;

    eprintln!("stored: PathInfoDb loaded");

    // Register the `store` scheme.
    // On Redox, this is done via:
    //   let socket = redox_scheme::Socket::create()?;
    //   redox_scheme::scheme::register_sync_scheme(&socket, "store", &mut handler)?;
    //
    // For now, this is a stub that will be filled in when we integrate
    // with the actual redox_scheme crate (requires Redox cross-compilation).

    eprintln!("stored: scheme registration requires redox_scheme crate");
    eprintln!("stored: this will be wired up when building for x86_64-unknown-redox");

    // The actual implementation will look like:
    //
    //   let socket = redox_scheme::Socket::create()?;
    //   let mut handler = StoreSchemeHandler::new(daemon);
    //   redox_scheme::scheme::register_sync_scheme(&socket, "store", &mut handler)?;
    //
    //   // Signal readiness (if started by daemon crate)
    //   // daemon_handle.ready();
    //
    //   loop {
    //       let req = socket.next_request(SignalBehavior::Restart)?;
    //       match req.kind() {
    //           RequestKind::Call(call) => {
    //               let response = call.handle_sync(&mut handler);
    //               socket.write_response(response, SignalBehavior::Restart)?;
    //           }
    //           RequestKind::OnClose { id } => handler.on_close(id),
    //           _ => continue,
    //       }
    //   }

    Err("stored: scheme registration not yet implemented for this target".into())
}

// The SchemeSync implementation will dispatch to the core modules:
//
// impl SchemeSync for StoreSchemeHandler {
//     fn openat(&mut self, _dirfd, path, flags, ..) -> Result<OpenResult> {
//         let resolved = resolve::parse_scheme_path(path)?;
//         let fs_path = resolve::to_filesystem_path(&resolved, &self.config.store_dir)?;
//
//         // Lazy extraction if needed
//         if let ResolvedPath::StorePathRoot { ref store_path_name }
//             | ResolvedPath::SubPath { ref store_path_name, .. } = resolved
//         {
//             if !resolve::is_extracted(store_path_name, &self.config.store_dir) {
//                 lazy::ensure_extracted(
//                     store_path_name,
//                     &self.config.store_dir,
//                     &self.config.cache_path,
//                     &self.daemon.db,
//                     &self.daemon.extracting,
//                 )?;
//             }
//         }
//
//         // Open file or directory
//         if fs_path.is_dir() {
//             let id = self.daemon.handles.open_dir(fs_path, path.to_string())?;
//             Ok(OpenResult::ThisScheme { number: id, flags: NewFdFlags::POSITIONED })
//         } else {
//             let id = self.daemon.handles.open_file(fs_path, path.to_string())?;
//             Ok(OpenResult::ThisScheme { number: id, flags: NewFdFlags::POSITIONED })
//         }
//     }
//
//     fn read(&mut self, id, buf, offset, ..) -> Result<usize> {
//         self.daemon.handles.read(id, buf, offset)
//     }
//
//     fn fstat(&mut self, id, stat, ..) -> Result<()> { ... }
//     fn getdents(&mut self, id, buf, offset) -> Result<DirentBuf> { ... }
//     fn fpath(&mut self, id, buf, ..) -> Result<usize> { ... }
//     fn fsize(&mut self, id, ..) -> Result<u64> { ... }
//     fn on_close(&mut self, id) { self.daemon.handles.close(id); }
// }
