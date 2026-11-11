# Troubleshooting

## A dead substituter or build farm blocks every command

Typical output:

```text
warning: unable to download 'http://100.100.103.95:39400/...narinfo': Could not connect
error: unable to download 'http://100.100.103.95:39400/...narinfo'
error: opening lock file "...grpc:__aspen1.local:50051...": File name too long
error: unexpected EOF reading a line
```

This comes from the **host Nix configuration**, not from the repository. A
tailnet substituter is offline and/or `/etc/nix/machines` contains a gRPC build
farm with credentials in the URL. Nix's lock-file path then exceeds the filename
limit.

Override both for one command:

```bash
nix run \
  --builders '' \
  --option build-hook '' \
  --option extra-substituters '' \
  --option substituters 'https://cache.nixos.org' \
  .#run-redox-self-hosting
```

Validate the same flags without launching a VM:

```bash
nix build --dry-run \
  --builders '' \
  --option build-hook '' \
  --option extra-substituters '' \
  --option substituters 'https://cache.nixos.org' \
  .#redox-self-hosting
```

For a durable fix, remove the dead cache and build farm from the host
configuration and rebuild:

- remove the `http://100.100.103.95:39400` entries from
  `nix.settings.extra-substituters`;
- remove the aspen1 entry from `nix.buildMachines` (or comment
  `/etc/nix/machines`);
- run `sudo nixos-rebuild switch`.

## Direnv falls back to the previous environment

The same host settings break `nix print-dev-env` during `use flake`. Pass the
overrides through the devshell invocation in `.envrc`:

```bash
use flake . \
  --builders '' \
  --option build-hook '' \
  --option extra-substituters ''
```

Then run `direnv reload`. If the shell still falls back, fix the host
configuration above; direnv is reporting the same failure as `nix run`.

## Headless boot looks alarming

`nix run .#headless` uses Cloud Hypervisor with **no display and no network
adapter**. Expect:

| Message | Why |
|---|---|
| `Framebuffer not found` | No GOP framebuffer; Orbital and `display.*` schemes cannot start. |
| `netstack: no network adapter found` | The headless runner disables networking by design. |
| `nc error: listen_tcp ... No such device` | The development profile enables the remote-shell listener; there is no NIC to bind. |
| `redoxfs failed to open .../0`, `.../0p0` | RedoxFS probes candidate disk paths before matching its UUID. Login success means the rootfs mounted. |
| `Unable to find HPET`, NUMA, `Failed to locate Outputs` | Firmware/platform limitations; nonfatal. |

For a desktop, use `nix run .` on a host with a display. For networking, use
`nix run .#run-redox-cloud-hypervisor-net` after configuring a TAP device, or
run `nix run .#network-test`.

## Never store tokens in nix.conf

`~/.config/nix/nix.conf` supports `access-tokens` for private flakes. Do not
put long-lived GitHub tokens there: the file is often copied into logs and
shell diagnostics. Prefer a credential helper, and rotate any token that has
been printed. This repository is public and does not require a token.

Remove such a line, revoke the token at the provider, and re-authenticate with
the appropriate tool (for example `gh auth login`).
