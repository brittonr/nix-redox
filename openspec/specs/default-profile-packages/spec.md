## default-profile-packages

The development profile should include tools the Redox OS book documents
as standard system tools.

### Requirements

- [REQ-CONTAIN] The development profile includes `contain` (namespace/
  container tool) via the `opt` pattern.

- [REQ-PKGUTILS] The development profile includes `pkgutils` (native
  package manager CLI — `pkg` command) via the `opt` pattern.

### Tests

- Eval test: development profile with contain and pkgutils available
  evaluates without error.
