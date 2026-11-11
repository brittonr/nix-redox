# Security policy

## Supported versions

`nix-redox` is alpha software. Security fixes are applied to the `main` branch;
older commits and tagged prereleases are not maintained.

## Reporting a vulnerability

Do **not** open a public issue for an unfixed vulnerability. Report it through
[GitHub Security Advisories](https://github.com/brittonr/nix-redox/security/advisories/new)
or email `b@robitzs.ch`. Include:

- the affected commit or image build,
- the command or configuration needed to reproduce it,
- the impact and any known constraints,
- a minimal proof of concept and suggested fix, if available.

You should receive an acknowledgement within a few days. Please allow time for
a fix and coordinated disclosure before publishing details.

## Scope

In scope:

- the Nix build, sandbox, and proxy code;
- VM launchers and image assembly;
- default system configuration and service units;
- the on-guest `snix` implementation and its privilege boundaries.

The default accounts (`user` / `redox` and `root` / `redox`) are documented demo
credentials for local VMs. They are not a vulnerability in the image itself, but
**change them before exposing a system to a network**. The same applies to demo
keys, empty passwords, and permissive service defaults intended for local
testing.

## Handling secrets

This repository must not contain credentials, private keys, tokens, or
machine-specific secrets. If you find one, report it privately rather than
opening an issue. If you accidentally commit a secret, rotate it immediately;
removing the commit is not sufficient.
