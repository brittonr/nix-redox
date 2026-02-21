# Plan

- [ ] **Run snix's `BuildService` on the host** — the host already has tokio, tonic, the full stack
- [ ] **Wire a channel from guest to host** — virtio-serial, virtio-vsock, or even shared filesystem
- [ ] **Guest evaluates Nix → produces `BuildRequest`** — snix-eval already has the `derivation` builtin, we just never call it
- [ ] **Host builds, guest receives outputs via binary cache protocol** — we already have NAR extraction working (`nar.rs`, `cache.rs`)
- [ ] **Guest activates from real store paths** — the existing activate.rs is actually fine for this part

Progress: 0/5 steps completed
