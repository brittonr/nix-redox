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
use redox_scheme::{RequestKind, Response, SignalBehavior, Socket};
use virtio_core::transport::Transport;

use crate::scheme::VirtioFsScheme;
use crate::session::FuseSession;

/// virtio-fs device config space layout.
/// The tag is a UTF-8 string identifying the filesystem instance.
/// Cloud Hypervisor sets this via --fs tag=<name>.
#[repr(C)]
struct VirtioFsConfig {
    tag: [u8; 36],
    num_request_queues: u32,
}

fn main() {
    pcid_interface::pci_daemon(daemon_runner);
}

fn daemon_runner(daemon: daemon::Daemon, pcid_handle: PciFunctionHandle) -> ! {
    run_daemon(daemon, pcid_handle).unwrap();
    unreachable!();
}

fn run_daemon(
    daemon: daemon::Daemon,
    mut pcid_handle: PciFunctionHandle,
) -> anyhow::Result<()> {
    common::setup_logging(
        "fs",
        "pci",
        "virtio-fsd",
        common::output_level(),
        common::file_level(),
    );

    let pci_config = pcid_handle.config();
    let device_id = pci_config.func.full_device_id.device_id;

    // virtio-fs modern device ID: 0x1040 + device_type(26) = 0x105A
    assert_eq!(
        device_id, 0x105A,
        "unexpected virtio-fs device ID: {:#x} (expected 0x105A)",
        device_id
    );
    log::info!("virtio-fsd: initiating startup sequence");

    // Probe the virtio device (reset, negotiate, set up PCI capabilities)
    let device = virtio_core::probe_device(&mut pcid_handle)?;

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

    log::info!(
        "virtio-fsd: tag='{}', num_request_queues={}",
        tag,
        num_request_queues
    );

    // Finalize feature negotiation
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
    log::info!("virtio-fsd: device is running");

    // Initialize the FUSE session
    let session = FuseSession::init(request_queue)
        .map_err(|e| anyhow::anyhow!("FUSE init failed: {}", e))?;

    log::info!("virtio-fsd: FUSE session initialized");

    // Register as a Redox scheme using the tag as the scheme name.
    // This makes the filesystem accessible at /scheme/<tag>/
    let socket = Socket::create()?;

    let scheme_name = tag.clone();
    let mut scheme = VirtioFsScheme::new(session, scheme_name.clone());

    redox_scheme::scheme::register_sync_scheme(&socket, &scheme_name, &mut scheme)?;

    log::info!("virtio-fsd: registered scheme '{}'", scheme_name);

    // Signal daemon readiness
    daemon.ready().unwrap();

    // Drop into null namespace (security: no further scheme access needed)
    libredox::call::setrens(0, 0).expect("virtio-fsd: failed to enter null namespace");

    // Main event loop: handle scheme requests
    loop {
        let req = match socket.next_request(SignalBehavior::Restart)? {
            None => break, // Socket closed
            Some(req) => match req.kind() {
                RequestKind::Call(r) => r,
                RequestKind::OnClose { id } => {
                    scheme.on_close(id);
                    continue;
                }
                _ => continue,
            },
        };

        let response = req.handle_sync(&mut scheme);

        if !socket.write_response(response, SignalBehavior::Restart)? {
            break;
        }
    }

    log::info!("virtio-fsd: shutting down");
    Ok(())
}
