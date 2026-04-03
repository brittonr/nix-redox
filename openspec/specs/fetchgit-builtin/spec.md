## ADDED Requirements

### Requirement: builtins.fetchGit evaluates to a store path
The evaluator SHALL support `builtins.fetchGit { url = "..."; rev = "..."; }` returning a store path containing the git working tree at the specified revision. The implementation SHALL invoke the `git` binary to perform the clone and checkout.

#### Scenario: fetchGit with HTTPS URL and rev
- **WHEN** snix evaluates `builtins.fetchGit { url = "https://example.com/repo.git"; rev = "abc123..."; }`
- **THEN** the result is a store path in `/nix/store/` containing the repo contents at that revision
- **AND** the `.git` directory is NOT included in the store path

#### Scenario: fetchGit with local file:// path
- **WHEN** snix evaluates `builtins.fetchGit { url = "file:///tmp/local-repo"; rev = "abc123..."; }`
- **THEN** the result is a store path containing the repo contents at that revision

#### Scenario: fetchGit with ref attribute
- **WHEN** snix evaluates `builtins.fetchGit { url = "..."; ref = "main"; }`
- **THEN** snix resolves `ref` to a commit hash and checks out that commit

#### Scenario: fetchGit result is cached
- **WHEN** `builtins.fetchGit` is called twice with the same URL and rev
- **THEN** the second call returns the cached store path without re-cloning

#### Scenario: fetchGit with narHash verification
- **WHEN** `builtins.fetchGit { url = "..."; rev = "..."; narHash = "sha256-..."; }` is evaluated
- **AND** the NAR hash of the checked-out tree matches the declared hash
- **THEN** the store path is returned

#### Scenario: fetchGit narHash mismatch
- **WHEN** the NAR hash of the checked-out tree does not match the declared `narHash`
- **THEN** snix returns an evaluation error with expected and actual hashes

### Requirement: Git locked inputs resolve in flake.lock
`flake.rs` SHALL handle `"type": "git"` locked inputs by invoking the fetchGit machinery. The locked input's `url` and `rev` fields SHALL be passed to the git fetch implementation.

#### Scenario: Flake with git-type locked input
- **WHEN** a `flake.lock` contains a node with `"locked": { "type": "git", "url": "https://...", "rev": "abc123...", "narHash": "sha256-..." }`
- **THEN** `snix build .#package` resolves the input to a store path via fetchGit
- **AND** the store path is passed to the flake evaluation as the input source

#### Scenario: Git input fallback to tarball for known forges
- **WHEN** a git-type input URL matches a GitHub or GitLab pattern
- **AND** the locked ref includes `narHash`
- **THEN** snix MAY download the archive tarball instead of git-cloning (optimization)

### Requirement: fetchGit errors are descriptive
When fetchGit fails, the error message SHALL identify the cause: git binary not found, clone failure, rev not found, or checkout failure.

#### Scenario: Git binary not found
- **WHEN** `builtins.fetchGit` is called and `git` is not in PATH
- **THEN** the error message mentions that the `git` command was not found

#### Scenario: Clone failure
- **WHEN** the git clone fails (network error, auth failure, invalid URL)
- **THEN** the error message includes the git stderr output
