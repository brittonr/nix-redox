## Why

Unsandboxed builders corrupt compiled objects: `ld.lld` reports
`section table goes past the end of file` for an rlib produced under
`$TMPDIR`. The build proxy already works around this by copying file-backed
mappings of mutable paths into private anonymous memory
(`snix-redox/src/build_proxy/io_worker.rs`), because RedoxFS recycles tree
node IDs on unlink while per-node fmap ranges can still hold frames from the
previous file. Direct execution (`snix build --no-sandbox`, the diagnostic
`direct-cc-dep-script` / `direct-rg-script` probes) still goes through the
plain `file:` scheme and hits the corruption.

## What Changes

- Make mutable-path mappings private/anonymous at the scheme or kernel layer
  so every file-backed mapping of a writable inode is isolated from node-ID
  recycling, not only mappings that pass through the build proxy.
- Add a focused regression that builds the cc-dep and ripgrep fixtures with
  `--no-sandbox` and runs the binaries.
- Once fixed, turn the `SKIP:unsandboxed-mutable-mapping` probes in
  `snix-sandbox-test.nix` and `self-hosting-test.nix` back into PASS checks.
- Keep the proxy copy path as defence in depth or remove it after the
  scheme-level fix is proven.

## Capabilities

### New Capabilities

- `mutable-mapping-isolation`: file-backed mappings of mutable inodes must not
  observe frames from a different file after the inode's tree node is
  recycled.

## Impact

- **Filesystem**: RedoxFS scheme mapping/fmap handling (and kernel mapping
  support if the fix belongs there)
- **snix**: build proxy workaround in `snix-redox/src/build_proxy/io_worker.rs`
- **Validation**: `nix/redox-system/profiles/snix-sandbox-test.nix`,
  `nix/redox-system/profiles/self-hosting-test.nix`, `--no-sandbox` builds
- **Docs**: AGENTS mutable-mapping note
