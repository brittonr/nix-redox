# Porting a package

Redox does not run Linux binaries. Packages must be built for
`x86_64-unknown-redox`, typically from source. The repository already carries
the cross-compiler, relibc sysroot, and per-crate cache; most Rust and C
packages need a package definition and a build plan, not a new toolchain.

## Rust packages

Most CLI tools are wired through `mkCrossPackage` in
`nix/flake-modules/packages.nix`:

```nix
ripgrep = mkCrossPackage {
  pname = "ripgrep";
  src = inputs.ripgrep-src;
  plan = ../pkgs/infrastructure/ripgrep-redox-plan.json;
  member = "ripgrep";
};
```

1. Add a pinned source input to `flake.nix` and regenerate `flake.lock`.
2. Generate a unit2nix build plan with the repository's toolchain and commit the
   plan next to the other `*-build-plan.json` files.
3. Add the package to the relevant profiles and, if it must survive profile
   activation, to the boot-essential set.
4. Add the package to the cross tier in `nix/flake-modules/checks.nix`.
5. Build and smoke-test:

```bash
nix build .#ripgrep
nix run .#test-cross
nix run .#push-to-redox -- ripgrep
```

Inside a running guest, install and execute the binary:

```bash
snix install ripgrep
rg --version
```

## C and C++ packages

Use `nix/pkgs/userspace/*.nix` and the clang cross-compiler. Build only static
archives or libraries; do not try to build upstream test/app binaries, because
the cross sysroot has no host runtime. Install headers, `.a` files, and any
required data manually. Follow the existing OpenSSL, bzip2, and fontconfig
definitions rather than adding a second convention.

Typical traps:

- `pkg-config` files must point at the Redox sysroot, not the host.
- `-nostdlib` in upstream flags breaks configure probes; strip it for probes.
- `-shared` builds need different CRT handling than static builds.
- `O_RDONLY`, `O_CREAT`, and file-mode constants differ from Linux.
- Some upstream crates select Linux code paths from `target_os`; patch the
  crate or use a per-crate override.

## Vendoring and hashes

- Cargo dependencies must be reachable offline. Add the source bundle or vendor
  hash and keep `.cargo/config.toml` pointing at the exact vendor directory.
- After changing a source tree or lockfile, refresh the fixed-output hash and
  the vendor hash. A stale vendor hash fails offline with a missing crate.
- Do not resolve lockfiles at build time. Commit the lockfile used by the
  package.
- Check the license. Do not package software without a license, and preserve
  upstream notices.

## CI and proof

The cross tier is the minimum gate. For a package that affects boot, add a VM
test and a guest assertion. For a package that affects the system profile, run
`nix run .#test-quick` and the relevant VM tier. Include the commands and results
in the pull request, and note what was not tested.

## What this is not

This is not a nixpkgs package bridge. Redox has its own C library and syscall
ABI, so a nixpkgs derivation is a starting point, not a drop-in. Porting the
source and validating it on Redox is the deliverable.
