"""Patch virtio-netd main loop to wake on IRQ events.

Without this fix, virtio-netd's main event loop only wakes when smolnetd sends
a scheme request. If smolnetd's timer goes idle (no active sockets), nobody polls
the device for incoming packets. This patch subscribes the IRQ file descriptor to
the main event queue so that hardware interrupts (from received packets) also
trigger a tick() call, which reads the packets and posts fevent to smolnetd.
"""

import sys

file_path = sys.argv[1]
with open(file_path, 'r') as f:
    content = f.read()

# 1. Add AsRawFd import
old_imports = "use std::fs::File;\nuse std::io::{Read, Write};\nuse std::mem;"
new_imports = "use std::fs::File;\nuse std::io::{Read, Write};\nuse std::mem;\nuse std::os::fd::AsRawFd;"

if old_imports in content:
    content = content.replace(old_imports, new_imports)
    print("Added AsRawFd import")
else:
    print("WARNING: Could not find imports to patch")
    sys.exit(1)

# 2. Clone IRQ handle before Device is shadowed, and subscribe to event queue
old_event_loop = """    let mut event_queue = File::open("/scheme/event")?;
    event_queue.write(&syscall::Event {
        id: scheme.event_handle().raw(),
        flags: syscall::EVENT_READ,
        data: 0,
    })?;

    libredox::call::setrens(0, 0).expect("virtio-netd: failed to enter null namespace");

    scheme.tick()?;

    loop {
        event_queue.read(&mut [0; mem::size_of::<syscall::Event>()])?; // Wait for event
        scheme.tick()?;
    }"""

new_event_loop = """    let mut event_queue = File::open("/scheme/event")?;
    event_queue.write(&syscall::Event {
        id: scheme.event_handle().raw(),
        flags: syscall::EVENT_READ,
        data: 0,
    })?;

    // Also subscribe IRQ handle so hardware interrupts (packet received)
    // wake the main loop and trigger tick() -> post_fevent to smolnetd.
    // Without this, the main loop only wakes on scheme requests from smolnetd,
    // creating a deadlock when smolnetd's timer goes idle.
    event_queue.write(&syscall::Event {
        id: irq_file.as_raw_fd() as usize,
        flags: syscall::EVENT_READ,
        data: 1,
    })?;

    libredox::call::setrens(0, 0).expect("virtio-netd: failed to enter null namespace");

    scheme.tick()?;

    loop {
        event_queue.read(&mut [0; mem::size_of::<syscall::Event>()])?; // Wait for event
        scheme.tick()?;
    }"""

if old_event_loop in content:
    content = content.replace(old_event_loop, new_event_loop)
    print("Patched event loop to subscribe IRQ handle")
else:
    print("WARNING: Could not find event loop to patch")
    sys.exit(1)

# 3. Clone IRQ handle before device is shadowed by VirtioNet::new()
old_device_init = "    let device = VirtioNet::new(mac_address, rx_queue, tx_queue);"
new_device_init = """    // Clone IRQ handle before the virtio-core Device is dropped (shadowed below).
    // We need the fd alive in the main scope for event queue subscription.
    let irq_file = device.irq_handle.try_clone()
        .expect("virtio-netd: failed to clone IRQ handle");

    let device = VirtioNet::new(mac_address, rx_queue, tx_queue);"""

if old_device_init in content:
    content = content.replace(old_device_init, new_device_init)
    print("Added IRQ handle clone before device shadow")
else:
    print("WARNING: Could not find device init to patch")
    sys.exit(1)

with open(file_path, 'w') as f:
    f.write(content)
