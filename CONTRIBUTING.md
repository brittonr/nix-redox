# Contributing to nix-redox

Thanks for helping build a reproducible Redox OS distribution. This guide covers
the development loop, where changes belong, and what a reviewable pull request
looks like.

## Development setup

You need an `x86_64-linux` host with Nix flakes enabled. KVM is required for VM
tests; a graphical display is required only for the desktop runner.

```bash
git clone https://github.com/brittonr/nix-redox
cd nix-redox
nix develop
```

Run the fast gate before sending a change:

```bash
nix run .#test-quick
```

Use the broader tiers when your change reaches them:

```bash
nix run .#test-host    # host tools and snix host tests
nix run .#test-cross   # cross-compiled Redox packages
nix run .#test-vm      # boot, functional, schemes, bridge
```

Focused suites are listed in the README. If you change a subsystem with its own
suite, run that suite and include the result in the pull request.

## Where changes belong

| Change | Location |
|---|---|
| New package | `nix/pkgs/userspace/` or `nix/pkgs/system/`, then wire it in `nix/flake-modules/packages.nix` |
| System option or service | `nix/redox-system/modules/` |
| Image profile | `nix/redox-system/profiles/` |
| VM runner or test harness | `nix/pkgs/infrastructure/` |
| Build plan or toolchain carry | `nix/patches/`, `nix/pkgs/system/patches/` |
| Guest-side snix code | `snix-redox/` |

Read the existing package or module nearest to your change and follow its
structure. Avoid introducing a second convention for the same job.

## Style and checks

- Format with `nix fmt` (treefmt). The repository uses `nixfmt-rfc-style`.
- Keep Nix expressions pure and pinned. Do not add `path:` flake inputs; CI and
  public users cannot fetch them.
- New source files under flake-referenced paths must be tracked by Git before
  `nix build` sees them.
- Preserve the per-function object split in the unwind stub libraries. A single
  object reintroduces the unwind-poisoning failure described in the source.
- Do not commit build logs, local capture paths, credentials, tokens, or
  machine-specific configuration. Sanitize logs before attaching them.

## Pull requests

- Keep changes focused and explain the behavioral contract, not just the diff.
- Include the commands you ran and their results. State explicitly what was not
  tested.
- Update docs and the changelog when behavior or user-facing commands change.
- Do not weaken assertions or delete tests to make a change pass. Fix the cause.
- By submitting a contribution, you agree that it is licensed under the
  repository's MIT license.

## Reporting bugs and security issues

Use the GitHub issue templates for reproducible bugs and feature requests.
Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md).
