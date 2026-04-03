## 1. VM-validate 4-gaps code (depends on fix-relibc-panic-abort)

- [ ] 1.1 Build self-hosting-test disk image with the 4-gaps commit included
- [ ] 1.2 Boot VM and run full self-hosting test suite, capture serial output
- [ ] 1.3 Triage failures: classify as sandbox gap, env var missing, Ion/bash script issue, or snix bug
- [ ] 1.4 Fix fetchGit test phase — ensure local bare repo + builtins.fetchGit works on guest
- [ ] 1.5 Fix flake installable test — ensure `snix build /usr/src/test-flake#hello` works on guest
- [ ] 1.6 Fix cc-dep test — ensure cc-rs build script invokes CC wrapper through sandbox
- [ ] 1.7 Fix workspace test — ensure multi-crate workspace builds through snix on guest
- [ ] 1.8 Fix source-rebuild dry-run test — ensure `snix system rebuild --source --dry-run` works
- [ ] 1.9 All five 4-gaps FUNC_TESTs pass: fetchgit, flake-build, cc-dep-build, workspace-build, source-rebuild-dryrun

## 2. Remote binary cache client

- [ ] 2.1 Add minreq to snix-redox Cargo.toml and vendor for cross-compilation
- [ ] 2.2 Implement `CacheSource::Remote` HTTP methods: fetch_package_index, fetch_narinfo, fetch_nar
- [ ] 2.3 Add connection error and HTTP status code handling with user-facing messages
- [ ] 2.4 Implement NAR hash verification after download (SHA-256 from narinfo NarHash)
- [ ] 2.5 Wire `--cache-url` flag into `snix install` command
- [ ] 2.6 Wire `--cache-url` flag into `snix system rebuild` package resolution
- [ ] 2.7 Host-side unit tests for remote cache source (mock HTTP or test fixtures)
- [ ] 2.8 VM test: boot guest, serve cache from host on port 8080, run `snix install ripgrep --cache-url http://10.0.2.2:8080`

## 3. Store scheme daemon (stored)

- [ ] 3.1 Implement stored binary entry point: pre-open root fd, register `store:` scheme, enter event loop
- [ ] 3.2 Implement open handler: parse store path from scheme-relative path, resolve to /nix/store/ via root fd
- [ ] 3.3 Implement lazy extraction: on first access to unextracted path, decompress NAR from /nix/cache/, verify hash, extract
- [ ] 3.4 Implement read/stat/readdir/close handlers for extracted paths
- [ ] 3.5 Add stored to Nix package set (new cross-compiled binary package)
- [ ] 3.6 Add stored init service definition (daemon type, started before dependent services)
- [ ] 3.7 Add `store` to login_schemes.toml for user session access
- [ ] 3.8 VM test: boot with stored, verify `cat store:hash-name/bin/rg` returns binary content

## 4. Full guest rebuild flow

- [ ] 4.1 Wire remote cache resolution into rebuild.rs: try remote → local → source fallback chain
- [ ] 4.2 Implement generation creation in rebuild: mkdir /nix/system/generations/N, write manifest.json + metadata.json
- [ ] 4.3 Update /nix/system/current symlink on successful activation
- [ ] 4.4 Implement rebuild-auto-routing: detect bridge vs remote vs local vs source
- [ ] 4.5 Add reboot-recommended detection when boot components change
- [ ] 4.6 Ship a test configuration.nix on the self-hosting image for rebuild testing
- [ ] 4.7 VM test: modify configuration.nix hostname, run rebuild, verify /etc/hostname changed
- [ ] 4.8 VM test: run rebuild, verify new generation in `snix system generations`

## 5. Generation management and rollback

- [ ] 5.1 Implement `snix system generations` — list generations with ID, timestamp, current marker
- [ ] 5.2 Implement `snix system switch-generation N` — activate generation N, update symlink and etc files
- [ ] 5.3 Implement `snix system rollback` — switch to generation N-1
- [ ] 5.4 Implement `snix system delete-generations` — remove specified generations, refuse current
- [ ] 5.5 Implement `--older-than` flag for age-based deletion
- [ ] 5.6 Add reboot-recommended warning when switching to generation with different boot components
- [ ] 5.7 VM test: rebuild twice, list generations, rollback, verify previous config restored

## 6. End-to-end rebuild validation

- [ ] 6.1 Add rebuild cycle test to self-hosting-test profile: change hostname via rebuild, verify
- [ ] 6.2 Add rebuild cycle test: add etc file via rebuild, verify file exists
- [ ] 6.3 Add rebuild cycle test: verify generation count after rebuild
- [ ] 6.4 All rebuild FUNC_TESTs pass: rebuild-hostname, rebuild-etc-file, rebuild-generation
