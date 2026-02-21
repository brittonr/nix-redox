//! virtio-fsd: VirtIO filesystem driver for Redox OS.
//!
//! Implements the virtio-fs device (device ID 26, PCI 0x1AF4:0x105A)
//! which speaks the FUSE protocol over virtqueues. The host runs virtiofsd
//! to serve a host directory to the guest.
//!
//! Architecture:
//!   Cloud Hypervisor --fs tag=shared,socket=/tmp/virtiofsd.sock
//!   → PCI device 0x1AF4:0x105A appears in guest
//!   → pcid-spawner starts this driver
//!   → Driver sets up virtqueues, sends FUSE_INIT
//!   → Registers as Redox scheme (e.g., /scheme/shared)
//!   → Programs access files via /scheme/shared/path/to/file
//!
//! This enables host↔guest shared directories — the critical channel for
//! the snix build bridge (guest evaluates config, host builds, shared dir
//! transfers outputs).

mod fuse;
mod scheme;
mod session;
mod transport;

use pcid_interface::PciFunctionHandle;
use redox_scheme::{RequestKind, SignalBehavior, Socket};

use crate::scheme::VirtioFsScheme;
use crate::session::FuseSession;

fn main() {
    pcid_interface::pci_daemon(daemon_runner);
}

fn daemon_runner(daemon: daemon::Daemon, pcid_handle: PciFunctionHandle) -> ! {
    match run_daemon(daemon, pcid_handle) {
        Ok(()) => eprintln!("virtio-fsd: daemon exited normally"),
        Err(e) => eprintln!("virtio-fsd: FATAL ERROR: {}", e),
    }
    unreachable!();
}

fn run_daemon(
    daemon: daemon::Daemon,
    mut pcid_handle: PciFunctionHandle,
) -> anyhow::Result<()> {
    // Use eprintln! for early-boot serial output (before logd is ready)
    eprintln!("virtio-fsd: starting driver initialization");

    common::setup_logging(
        "fs",
        "pci",
        "virtio-fsd",
        common::output_level(),
        common::file_level(),
    );

    let pci_config = pcid_handle.config();
    let device_id = pci_config.func.full_device_id.device_id;

    eprintln!("virtio-fsd: PCI device ID: {:#x}", device_id);

    // virtio-fs modern device ID: 0x1040 + device_type(26) = 0x105A
    assert_eq!(
        device_id, 0x105A,
        "unexpected virtio-fs device ID: {:#x} (expected 0x105A)",
        device_id
    );
    eprintln!("virtio-fsd: initiating startup sequence");

    // Probe the virtio device (reset, negotiate, set up PCI capabilities)
    eprintln!("virtio-fsd: probing virtio device...");
    let device = virtio_core::probe_device(&mut pcid_handle)?;
    eprintln!("virtio-fsd: virtio device probed successfully");

    // Read the filesystem tag from device config space.
    let tag = {
        let mut tag_bytes = [0u8; 36];
        for i in 0..36 {
            let byte = device.transport.load_config(i as u8, 1) as u8;
            tag_bytes[i] = byte;
        }
        // Find the null terminator
        let len = tag_bytes.iter().position(|&b| b == 0).unwrap_or(36);
        String::from_utf8_lossy(&tag_bytes[..len]).to_string()
    };

    // Read number of request queues
    let num_request_queues = device.transport.load_config(36, 4) as u32;

    eprintln!(
        "virtio-fsd: tag='{}', num_request_queues={}",
        tag,
        num_request_queues
    );

    // Finalize feature negotiation
    eprintln!("virtio-fsd: finalizing features...");
    device.transport.finalize_features();

    // Set up virtqueues:
    //   Queue 0: hiprio (high-priority, for FORGET etc.)
    //   Queue 1: request queue (normal FUSE operations)
    let _hiprio_queue = device
        .transport
        .setup_queue(virtio_core::MSIX_PRIMARY_VECTOR, &device.irq_handle)?;

    let request_queue = device
        .transport
        .setup_queue(virtio_core::MSIX_PRIMARY_VECTOR, &device.irq_handle)?;

    // Device is alive
    device.transport.run_device();
    eprintln!("virtio-fsd: device is running, setting up queues...");

    // Initialize the FUSE session
    eprintln!("virtio-fsd: sending FUSE_INIT...");
    let session = FuseSession::init(request_queue)
        .map_err(|e| {
            eprintln!("virtio-fsd: FUSE init FAILED: {}", e);
            anyhow::anyhow!("FUSE init failed: {}", e)
        })?;

    eprintln!("virtio-fsd: FUSE session initialized successfully");

    // Register as a Redox scheme using the tag as the scheme name.
    // This makes the filesystem accessible at /scheme/<tag>/
    eprintln!("virtio-fsd: creating scheme socket...");
    let socket = Socket::create()?;

    let mut scheme_handler = VirtioFsScheme::new(session, tag.clone());

    // Register the scheme (calls scheme_root internally)
    eprintln!("virtio-fsd: registering scheme '{}'...", tag);
    redox_scheme::scheme::register_sync_scheme(&socket, &tag, &mut scheme_handler)?;

    eprintln!("virtio-fsd: scheme '{}' registered successfully!", tag);

    // Signal daemon readiness (consumes daemon)
    daemon.ready();

    // Drop into null namespace (security: no further scheme access needed)
    libredox::call::setrens(0, 0).expect("virtio-fsd: failed to enter null namespace");

    // Main event loop: handle scheme requests
    loop {
        let req = match socket.next_request(SignalBehavior::Restart)? {
            None => break, // Socket closed
            Some(req) => req,
        };

        match req.kind() {
            RequestKind::Call(call_req) => {
                // handle_sync is on CallRequest, dispatches to SchemeSync trait methods
                let response = call_req.handle_sync(&mut scheme_handler);
                if !socket.write_response(response, SignalBehavior::Restart)? {
                    break;
                }
            }
            RequestKind::OnClose { id } => {
                use redox_scheme::scheme::SchemeSync;
                scheme_handler.on_close(id);
            }
            _ => continue,
        }
    }

    log::info!("virtio-fsd: shutting down");
    Ok(())
}
