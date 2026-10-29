## 1. Reproduce and localize

- [x] 1.1 Capture the unsandboxed corruption from `direct-cc-dep-script` with
  the `ld.lld` `section table goes past the end of file` error and the
  affected `$TMPDIR` object path.
  - `evidence/2026-10-28-direct-cc-dep-fail.excerpt.txt` (capture
    `/var/tmp/redox-self-hosting-captures/20261028T155026-snix-sandbox-test`):
    the object is `/tmp/direct-cc-dep-tmp/target/debug/build/cc-dep-test-.../build_script_build-...rcgu.o`.
- [x] 1.2 Determine whether the stale pages come from RedoxFS fmap range
  reuse, the kernel's scheme mapping path, or both.
  - RedoxFS scheme `fmap` entries were keyed by tree node id. After unlink the
    id is recycled while the previous anonymous base can still be mapped, so a
    new file reused that base. Evidence: on-disk object parsed fine after the
    failure, but a scheme-side in-place refresh of the shared base crashed the
    mapped build-script executable. The kernel's CoW grant is faithful to the
    scheme buffer; the scheme keying is the source.

## 2. Fix mutable mappings

- [x] 2.1 Implement private/anonymous copies (or range invalidation) for
  file-backed mappings of mutable inodes in the scheme/kernel path.
  - Implemented generation-keyed entries instead of in-place copies:
    `nix/patches/redoxfs-fmap-generation.patch` adds
    `FileResource::fmap_id` + `node_fmap_ids`, retires the id on unlink, and
    releases the entry/base on close. A recycled node id gets a fresh base
    while old mappings keep theirs.
- [x] 2.2 Keep read-only store/profile mappings zero-copy.
  - The patch changes only entry identity; store/profile fmap traffic and the
    proxy's immutable-path zero-copy path are unchanged.

## 3. Validate

- [x] 3.1 Add a `--no-sandbox` cc-dep/ripgrep build regression.
  - The direct unsandboxed probes (`direct-cc-dep-script`,
    `direct-rg-script`) are now hard failures instead of mutable-mapping
    skips; both pass in the 2026-10-28 sandbox run.
- [x] 3.2 Flip the `SKIP:unsandboxed-mutable-mapping` probes back to PASS and
  rerun `snix-sandbox-test` and `self-hosting-test`.
  - Failure branches now emit FAIL, not SKIP. Generation-keyed fmaps pass
    19/19 in `20261028T163222-snix-sandbox-test`; the full suite with the
    hard-failure policy passes 84/84 in
    `20261028T164427-self-hosting-test`, with zero failures or skips.
- [x] 3.3 Record capture artifacts under this change's `evidence/` directory.
  - Failure reproduction, focused sandbox proof, and full self-hosting proof
    are retained as dated excerpts. The full-run excerpt records the dirty
    base revision and the uncounted runtime-environment diagnostic crash;
    the 84/84 result is not a claim that every ad hoc diagnostic succeeded.
  - `docs/self-hosting/latest-success.{json,md}` was refreshed by the proof
    wrapper with both successful mapping-fix runs.
