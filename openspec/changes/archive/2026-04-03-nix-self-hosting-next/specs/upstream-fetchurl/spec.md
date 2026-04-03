## ADDED Requirements

### Requirement: fetchGit fetch variant supported in fetcher dispatch
The fetcher infrastructure SHALL handle `Fetch::Git()` variants by invoking the `git` CLI to clone and checkout a repository. When a `builtin:fetchurl`-style derivation or a `builtins.fetchGit` call produces a `Fetch::Git` variant, the fetcher SHALL clone the repo to a temp directory, checkout the specified revision, strip the `.git` directory, and copy the working tree to the output store path.

#### Scenario: Git fetch dispatches to git CLI
- **WHEN** the fetcher processes a `Fetch::Git` variant with URL and rev
- **THEN** it runs `git clone --bare <url> <tmpdir>` followed by `git --work-tree=<out> checkout <rev> -- .`
- **AND** the `.git` directory is not included in the output

#### Scenario: Git fetch verifies NAR hash when provided
- **WHEN** the `Fetch::Git` variant includes an expected NAR hash
- **THEN** the fetcher computes the NAR hash of the output directory
- **AND** compares it against the expected hash
- **AND** returns an error if they don't match

### Requirement: fetchTarball supports git archive URLs
The existing `Fetch::Tarball` handler SHALL continue to work for GitHub/GitLab archive URLs that return `.tar.gz` archives of git repositories. This is the fast path for forge-hosted repos.

#### Scenario: GitHub archive tarball unchanged
- **WHEN** a `Fetch::Tarball` is processed with a URL matching `https://github.com/*/archive/*.tar.gz`
- **THEN** the tarball is downloaded, decompressed, extracted, and the top-level directory stripped
- **AND** behavior is identical to the existing implementation (no regression)
