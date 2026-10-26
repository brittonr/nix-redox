## 1. Reproduce and localize

- [ ] 1.1 Capture the unsandboxed corruption from `direct-cc-dep-script` with
  the `ld.lld` `section table goes past the end of file` error and the
  affected `$TMPDIR` object path.
- [ ] 1.2 Determine whether the stale pages come from RedoxFS fmap range
  reuse, the kernel's scheme mapping path, or both.

## 2. Fix mutable mappings

- [ ] 2.1 Implement private/anonymous copies (or range invalidation) for
  file-backed mappings of mutable inodes in the scheme/kernel path.
- [ ] 2.2 Keep read-only store/profile mappings zero-copy.

## 3. Validate

- [ ] 3.1 Add a `--no-sandbox` cc-dep/ripgrep build regression.
- [ ] 3.2 Flip the `SKIP:unsandboxed-mutable-mapping` probes back to PASS and
  rerun `snix-sandbox-test` and `self-hosting-test`.
- [ ] 3.3 Record capture artifacts under this change's `evidence/` directory.
