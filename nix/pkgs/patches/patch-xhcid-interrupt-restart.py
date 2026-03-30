#!/usr/bin/env python3
"""Patch xhcid transfer() to log interrupt endpoint diagnostics via eprintln.

DIAGNOSTIC ONLY — no stop/restart commands. eprintln! goes to debug: scheme
which the kernel writes to the serial port. Capture with serial terminal.

Usage: python3 patch-xhcid-interrupt-restart.py <path-to-xhcid-scheme.rs>
"""
import sys


def main():
    path = sys.argv[1]

    with open(path, "r") as f:
        content = f.read()

    # 1. In transfer(), save endpoint type info before port_state is dropped.

    old_max_transfer = """\
        let max_packet_size = endp_desc.max_packet_size;
        let max_transfer_size = 65536u32;"""

    new_max_transfer = """\
        let max_packet_size = endp_desc.max_packet_size;
        let max_transfer_size = 65536u32;
        let is_interrupt_endp = endp_desc.is_interrupt();
        let endp_direction = endp_desc.direction();"""

    if old_max_transfer not in content:
        print("ERROR: max_packet_size/max_transfer_size pattern not found")
        sys.exit(1)

    content = content.replace(old_max_transfer, new_max_transfer, 1)
    print("Saved endpoint type flags")

    # 2. Add eprintln before execute_transfer for interrupt endpoints.

    old_drop_port = """\
        drop(port_state);

        let event = self
            .execute_transfer(
                port_num,
                endp_num,
                stream_id,
                "CUSTOM_TRANSFER","""

    new_drop_port = """\
        drop(port_state);

        if is_interrupt_endp {
            eprintln!("xhcid: XFER port={} ep={} dir={:?} len={}",
                port_num, endp_num, endp_direction,
                dma_buf.as_ref().map(|b| b.len()).unwrap_or(0));
        }

        let event = self
            .execute_transfer(
                port_num,
                endp_num,
                stream_id,
                "CUSTOM_TRANSFER","""

    if old_drop_port not in content:
        print("ERROR: drop(port_state)/execute_transfer pattern not found")
        sys.exit(1)

    content = content.replace(old_drop_port, new_drop_port, 1)
    print("Added pre-transfer eprintln")

    # 3. After execute_transfer, log result. NO stop/restart.

    old_after_transfer = """\
        //self.event_handler_finished();

        let bytes_transferred = dma_buf
            .as_ref()
            .map(|buf| buf.len() as u32 - event.transfer_length())
            .unwrap_or(0);

        Ok((event.completion_code(), bytes_transferred, dma_buf))"""

    new_after_transfer = """\
        //self.event_handler_finished();

        if is_interrupt_endp {
            eprintln!("xhcid: DONE port={} ep={} cc=0x{:X} remain={} xferred={}",
                port_num, endp_num, event.completion_code(), event.transfer_length(),
                dma_buf.as_ref().map(|b| b.len() as u32).unwrap_or(0).saturating_sub(event.transfer_length()));
        }

        let bytes_transferred = dma_buf
            .as_ref()
            .map(|buf| buf.len() as u32 - event.transfer_length())
            .unwrap_or(0);

        Ok((event.completion_code(), bytes_transferred, dma_buf))"""

    if old_after_transfer not in content:
        print("ERROR: post-execute_transfer pattern not found")
        sys.exit(1)

    content = content.replace(old_after_transfer, new_after_transfer, 1)
    print("Added post-transfer eprintln (diagnostics only)")

    with open(path, "w") as f:
        f.write(content)

    print("xhcid diagnostic patch applied (no stop/restart)")


if __name__ == "__main__":
    main()
