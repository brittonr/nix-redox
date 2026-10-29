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

- Key RedoxFS scheme fmap entries by a non-recycled generation ID instead of
  the filesystem node ID. Retire the node-to-generation association on final
  unlink; old mappings retain their original entry, while a recycled node
  receives a fresh anonymous base. Release unused entries and their bases.
- Require the direct unsandboxed cc-dep and ripgrep fixture builds to pass.
  These probes invoke the fixture scripts outside snix and exercise the
  plain `file:` scheme used by `snix build --no-sandbox`; the captures do not
  claim a separate literal `--no-sandbox` invocation. Retain the sandboxed
  snix build-and-run coverage.
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
