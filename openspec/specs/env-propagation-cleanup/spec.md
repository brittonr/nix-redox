## ADDED Requirements

### Requirement: env-set-investigation
Determine whether the `--env-set` workaround can be removed by testing the
specific failure mode with a minimal reproducer.

#### Scenario: minimal env!() crate without --env-set
- **WHEN** a crate using `env!("CARGO_PKG_NAME")` is compiled by cargo on Redox without the `--env-set` patch
- **THEN** the result is documented: either it compiles (workaround removable) or it fails with a specific error (workaround permanent, with documented reason)

### Requirement: env-set-disposition-documented
The final disposition of the `--env-set` workaround must be recorded in the
napkin and in code comments.

#### Scenario: workaround kept
- **WHEN** investigation shows `--env-set` cannot be removed
- **THEN** `rustc-redox.nix` comment explains: which env vars fail, why execvpe doesn't fix them, and what upstream change would allow removal

#### Scenario: workaround removed
- **WHEN** investigation shows `--env-set` is no longer needed
- **THEN** `patch-cargo-env-set.py` is deleted, `rustc-redox.nix` removes the patch application line, and all self-hosting tests still pass
