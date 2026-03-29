#!/usr/bin/env python3
"""Patch inputd's ProducerHandle::new() to add a 5-second timeout.

Without this, usbhidd blocks forever if inputd hasn't registered the
input: scheme yet. The timeout uses a thread + mpsc channel to avoid
blocking the main thread on File::open.

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
        Self::new_with_timeout(5)
    }

    pub fn new_with_timeout(timeout_secs: u64) -> io::Result<Self> {
        // Use a thread to avoid blocking forever if inputd hasn't registered yet.
        // The thread performs the blocking File::open, and we wait with a timeout.
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(File::open("/scheme/input/producer"));
        });
        match rx.recv_timeout(std::time::Duration::from_secs(timeout_secs)) {
            Ok(result) => result.map(ProducerHandle),
            Err(_) => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "input scheme not available within timeout",
            )),
        }
    }"""

    if old not in content:
        print("WARNING: ProducerHandle::new() pattern not found, skipping")
        return

    content = content.replace(old, new, 1)

    with open(path, "w") as f:
        f.write(content)

    print("ProducerHandle timeout patch applied")


if __name__ == "__main__":
    main()
