#!/usr/bin/env python3
"""Patch randd to allow reads from SchemeRoot handles.

Rust's std::sys::random::redox opens /scheme/rand (the scheme root)
and reads random bytes from it. But randd's read() only accepts
Handle::File, not Handle::SchemeRoot, returning EBADF.

Fix: allow reads from SchemeRoot handles (always permitted).
"""
import sys

path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

old_read = "    fn read(\n" \
    "        &mut self,\n" \
    "        id: usize,\n" \
    "        buf: &mut [u8],\n" \
    "        _offset: u64,\n" \
    "        _fcntl_flags: u32,\n" \
    "        _ctx: &CallerCtx,\n" \
    "    ) -> Result<usize> {\n" \
    "        // Check fd and permissions\n" \
    "        self.can_perform_op_on_fd(id, MODE_READ)?;"

new_read = "    fn read(\n" \
    "        &mut self,\n" \
    "        id: usize,\n" \
    "        buf: &mut [u8],\n" \
    "        _offset: u64,\n" \
    "        _fcntl_flags: u32,\n" \
    "        _ctx: &CallerCtx,\n" \
    "    ) -> Result<usize> {\n" \
    "        // Check fd and permissions -- allow reads from SchemeRoot\n" \
    "        // (Rust std opens /scheme/rand directly and reads from it)\n" \
    "        match self.handles.get(&id).ok_or(Error::new(EBADF))? {\n" \
    "            Handle::SchemeRoot => { /* scheme root is always readable */ }\n" \
    "            Handle::File(_) => { self.can_perform_op_on_fd(id, MODE_READ)?; }\n" \
    "        }"

if old_read in content:
    content = content.replace(old_read, new_read)
    print("Patched randd read() to accept SchemeRoot handles")
else:
    print("WARNING: Could not find randd read() method to patch")
    sys.exit(1)

with open(path, "w") as f:
    f.write(content)
