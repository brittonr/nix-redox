#!/usr/bin/env python3
"""Patch inputd's ProducerHandle::new() to retry with backoff.

On Redox, File::open on a non-existent scheme returns ENODEV immediately
(doesn't block). usbhidd is spawned by xhcid when USB HID devices are
detected, but inputd may not have registered the input: scheme yet.

This patch replaces the single open attempt with a retry loop:
try every 500ms for up to 30 seconds. This handles both race conditions
(inputd starting up) and the case where the open would block.

Usage: python3 patch-usbhidd-timeout.py <path-to-inputd-lib.rs>
"""
import sys


def main():
    path = sys.argv[1]

    with open(path, "r") as f:
        content = f.read()

    old = """    pub fn new() -> io::Result<Self> {
        File::open("/scheme/input/producer").map(ProducerHandle)
    }"""

    new = """    pub fn new() -> io::Result<Self> {
        Self::new_with_retry(30, 500)
    }

    pub fn new_with_retry(max_attempts: u32, interval_ms: u64) -> io::Result<Self> {
        // Retry opening input:producer with backoff.
        // On Redox, opening a non-existent scheme returns ENODEV immediately
        // (no blocking), so we need an explicit retry loop to wait for inputd
        // to register the input: scheme.
        let mut last_err = None;
        for attempt in 0..max_attempts {
            match File::open("/scheme/input/producer") {
                Ok(f) => return Ok(ProducerHandle(f)),
                Err(e) => {
                    if attempt == 0 {
                        eprintln!("usbhidd: input: scheme not ready, retrying for {}s...",
                            (max_attempts as u64 * interval_ms) / 1000);
                    }
                    last_err = Some(e);
                    std::thread::sleep(std::time::Duration::from_millis(interval_ms));
                }
            }
        }
        Err(last_err.unwrap_or_else(|| io::Error::new(
            io::ErrorKind::NotFound,
            "input scheme not available after retries",
        )))
    }"""

    if old not in content:
        print("WARNING: ProducerHandle::new() pattern not found, skipping")
        return

    content = content.replace(old, new, 1)

    with open(path, "w") as f:
        f.write(content)

    print("ProducerHandle retry patch applied")


if __name__ == "__main__":
    main()
