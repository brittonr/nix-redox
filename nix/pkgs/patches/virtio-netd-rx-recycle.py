"""Patch virtio-netd to fix RX buffer recycling and used ring tracking.

Bug 1: try_recv() never re-posts consumed buffers to the available ring.
  After ~256 packets, all RX buffers are exhausted and inbound packets are dropped.
Bug 2: try_recv() reads only the last used ring element (idx-1) and jumps recv_head
  to head_index(), skipping any intermediate packets.
Fix: Process one entry at recv_head per call, re-post the buffer after reading.
"""

import sys

file_path = sys.argv[1]
with open(file_path, 'r') as f:
    content = f.read()

old_try_recv = """    /// Returns the number of bytes read. Returns `0` if the operation would block.
    fn try_recv(&mut self, target: &mut [u8]) -> usize {
        let header_size = core::mem::size_of::<VirtHeader>();

        if self.recv_head == self.rx.used.head_index() {
            // The read would block.
            return 0;
        }

        let idx = self.rx.used.head_index() as usize;
        let element = self.rx.used.get_element_at(idx - 1);

        let descriptor_idx = element.table_index.get();
        let payload_size = element.written.get() as usize - header_size;

        // XXX: The header and packet are added as one output descriptor to the transmit queue,
        //      and the device is notified of the new entry (see 5.1.5 Device Initialization).
        let buffer = &self.rx_buffers[descriptor_idx as usize];
        // TODO: Check the header.
        let _header = unsafe { &*(buffer.as_ptr() as *const VirtHeader) };
        let packet = &buffer[header_size..(header_size + payload_size)];

        // Copy the packet into the buffer.
        target[..payload_size].copy_from_slice(&packet);

        self.recv_head = self.rx.used.head_index();
        payload_size
    }"""

new_try_recv = """    /// Returns the number of bytes read. Returns `0` if the operation would block.
    fn try_recv(&mut self, target: &mut [u8]) -> usize {
        let header_size = core::mem::size_of::<VirtHeader>();

        if self.recv_head == self.rx.used.head_index() {
            // The read would block.
            return 0;
        }

        // Read one entry at recv_head (not the last entry)
        let idx = self.recv_head as usize;
        let queue_size = self.rx.descriptor_len();
        let element = self.rx.used.get_element_at(idx % queue_size);

        let descriptor_idx = element.table_index.get();
        let payload_size = element.written.get() as usize - header_size;

        let buffer = &self.rx_buffers[descriptor_idx as usize];
        let _header = unsafe { &*(buffer.as_ptr() as *const VirtHeader) };
        let packet = &buffer[header_size..(header_size + payload_size)];

        // Copy the packet into the caller's buffer.
        target[..payload_size].copy_from_slice(&packet);

        // Re-post this buffer to the available ring so the device can reuse it.
        // The descriptor table entry still has the correct buffer address/flags from init.
        self.rx.repost_buffer(descriptor_idx as u16);

        // Advance recv_head by one (wrapping u16)
        self.recv_head = self.recv_head.wrapping_add(1);
        payload_size
    }"""

if old_try_recv in content:
    content = content.replace(old_try_recv, new_try_recv)
    print("Patched try_recv: fixed RX buffer recycling and used ring tracking")
else:
    print("WARNING: Could not find try_recv to patch")
    sys.exit(1)

with open(file_path, 'w') as f:
    f.write(content)
