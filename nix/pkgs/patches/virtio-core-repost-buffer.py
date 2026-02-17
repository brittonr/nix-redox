"""Patch virtio-core to add Queue::repost_buffer() method.

This method re-adds a descriptor to the available ring without going through
the descriptor_stack. Used by virtio-netd to recycle RX buffers after reading.
The descriptor table entry already has the correct buffer address/flags from
the initial setup, so we just need to add it back to the available ring and
notify the device.
"""

import sys
import re

file_path = sys.argv[1]
with open(file_path, 'r') as f:
    content = f.read()

old_descriptor_len = """    /// Returns the number of descriptors in the descriptor table of this queue.
    pub fn descriptor_len(&self) -> usize {
        self.descriptor.len()
    }
}"""

new_descriptor_len = """    /// Returns the number of descriptors in the descriptor table of this queue.
    pub fn descriptor_len(&self) -> usize {
        self.descriptor.len()
    }

    /// Re-post a descriptor to the available ring without allocating a new one.
    ///
    /// The descriptor table entry must already be set up with the correct buffer
    /// address, flags, and size (e.g. from initial queue population). This just
    /// adds the descriptor index back to the available ring and notifies the device.
    pub fn repost_buffer(&self, descriptor_idx: u16) {
        use core::sync::atomic::Ordering;

        let avail_idx = self.available.head_index() as usize;
        self.available
            .get_element_at(avail_idx)
            .table_index
            .store(descriptor_idx, Ordering::SeqCst);
        self.available.set_head_idx(avail_idx as u16 + 1);
        self.notification_bell.ring(self.queue_index);
    }
}"""

if old_descriptor_len in content:
    content = content.replace(old_descriptor_len, new_descriptor_len)
    print("Added Queue::repost_buffer() method")
else:
    print("WARNING: Could not find descriptor_len to patch")
    sys.exit(1)

with open(file_path, 'w') as f:
    f.write(content)
