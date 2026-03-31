## 1. Nix Module Options

- [x] 1.1 Add `boot.initDebug` boolean option (default `false`) to `nix/redox-system/modules/boot.nix`
- [x] 1.2 Add `boot.initSkip` list-of-strings option (default `[]`) to `nix/redox-system/modules/boot.nix`
- [x] 1.3 Forward both options through `nix/redox-system/modules/build/config.nix` into the cfg record

## 2. Bootstrap Patch

- [x] 2.1 Write a Python patch script (`nix/patches/patch-bootstrap-init-env.py`) that modifies `bootstrap/src/exec.rs` in the base source to read `/scheme/initfs/etc/init.env` after the existing `envs.push(b"LD_LIBRARY_PATH=...")` line
- [x] 2.2 The patch reads the file via `syscall::openat` on the initfs scheme fd into a fixed-size stack buffer (same pattern as the existing `env_bytes` read from `sys:env`)
- [x] 2.3 Split the file contents on `b'\n'`, filter empty lines, and push each line as a `&[u8]` to the `envs` vector — the buffer must be `static` or leaked since `envs` holds `&[u8]` references that outlive the read
- [x] 2.4 If the `openat` fails (file doesn't exist), proceed silently — no error, no change to existing behavior
- [x] 2.5 Wire the patch into the base package build (add to the existing patch list in the base derivation)

## 3. Initfs Env File Generation

- [x] 3.1 In `nix/redox-system/modules/build/initfs.nix`, generate `etc/init.env` content when `cfg.initDebug` is true or `cfg.initSkip` is non-empty
- [x] 3.2 Write `INIT_LOG_LEVEL=DEBUG` when `initDebug` is true; write `INIT_SKIP=cmd1,cmd2,...` when `initSkip` is non-empty
- [x] 3.3 Write the file into the initfs image build directory (`initfs/etc/init.env`) only when content is non-empty

## 4. Verification

- [x] 4.1 Build a test image with `boot.initDebug = true` and confirm `etc/init.env` with `INIT_LOG_LEVEL=DEBUG` is in the initfs
- [x] 4.2 Boot the debug image in QEMU and confirm init debug output appears on serial (lines matching `Starting`, `Reached target`)
- [x] 4.3 Build an image with `boot.initSkip = ["hwd"]` and verify `INIT_SKIP=hwd` in the initfs env file
- [x] 4.4 Build a default image (no options set) and verify no `etc/init.env` in initfs
