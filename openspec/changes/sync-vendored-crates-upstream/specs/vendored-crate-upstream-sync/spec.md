## ADDED Requirements

### Requirement: Vendored crate carries have an explicit disposition
The repository SHALL maintain an auditable inventory for vendored crates, forked crate sources, and patched vendored dependencies that affect Redox builds. Each inventory entry SHALL record the owning package or workspace, the local carry type, the upstream candidate or current upstream pin, the current disposition (`update`, `keep-local`, or `defer`), and the validation path required for a safe change.

#### Scenario: Inventory covers current local carries
- **WHEN** a maintainer reviews the vendored-crate sync inventory
- **THEN** each current vendored or forked crate carry has a corresponding entry with owner, source kind, disposition, and validation notes

#### Scenario: Disposition changes are traceable
- **WHEN** a vendored crate is updated to upstream or kept local after review
- **THEN** the inventory records the new disposition and the reason for that decision

### Requirement: Upstream sources are preferred when validation passes
For any vendored crate or forked crate source touched by this change, the build definitions SHALL prefer an upstream release or upstream commit instead of a Redox-local carry whenever host and guest validation prove the upstream source preserves required behavior.

#### Scenario: Upstream release replaces a stale local carry
- **WHEN** an existing local fork or patched vendored crate is found to build and run correctly from upstream source
- **THEN** the package definition switches to that upstream source and removes the unnecessary local carry

#### Scenario: Upstream sync preserves offline builds
- **WHEN** a crate source is switched from local carry to upstream
- **THEN** the resulting package or source bundle still resolves dependencies offline through the repository's normal vendoring path

### Requirement: Remaining local carries are documented as exceptions
If a vendored crate, forked source, or vendored patch remains local after review, the repository SHALL record the blocking Redox-specific issue, the package paths that still depend on the carry, and the condition that would justify another upstream sync attempt.

#### Scenario: Redox-specific blocker keeps a local carry
- **WHEN** upstream source still fails due to a Redox-only compile, runtime, or packaging gap
- **THEN** the exception record names that blocker and the smallest validation that would detect a future fix

#### Scenario: Deferred carry has a retry trigger
- **WHEN** a local carry is left in place
- **THEN** its record includes a concrete retry trigger such as an upstream release, a Redox ABI fix, or a removed downstream patch dependency

### Requirement: Build metadata stays synchronized with crate-source changes
Whenever an upstream sync changes Cargo dependency resolution, workspace membership, or fixed-output vendor content, the repository SHALL update the corresponding Cargo.lock files, vendor hashes, build plans, and source-bundle metadata needed for reproducible offline builds.

#### Scenario: Workspace sync updates derived metadata
- **WHEN** an upstream crate update changes a workspace lockfile or dependency graph
- **THEN** all checked-in build metadata derived from that graph is regenerated to match the new source state

#### Scenario: Fixed-output vendoring still matches content
- **WHEN** a package continues to use fixed-output vendoring after a crate-source change
- **THEN** the configured vendor hash matches the fetched content without manual post-build patching

### Requirement: Shared-source vendor patches are safe to reapply
If a patch can run in both a packaged-build flow and a guest source-bundle flow against the same logical crate source, the patch application step SHALL be idempotent or SHALL detect prior application and exit without corrupting the source tree.

#### Scenario: Shared-source patch is idempotent
- **WHEN** a vendor patch is applied twice through two valid build paths
- **THEN** the second application leaves the source tree in the same usable state instead of failing or double-mutating the file

#### Scenario: Prior application is detected
- **WHEN** a patch script cannot be made naturally idempotent
- **THEN** it detects prior application before rewriting the source and skips or errors with a clear diagnostic

### Requirement: Validation scales with crate blast radius
Each vendored-crate upstream sync SHALL run the smallest validation that proves the touched package still works, and SHALL escalate to guest or self-hosting validation whenever the change affects Redox-native runtime behavior, source bundles, or self-hosting build paths. Any package that appears in a guest source bundle, VM profile, or self-hosting input path SHALL be classified as guest-facing even if it also builds or runs on the host.

#### Scenario: Host-only packaged tool uses host validation
- **WHEN** an upstream sync only affects a host-side package path
- **THEN** host-side build or test checks are sufficient if they cover the touched behavior

#### Scenario: Guest-facing crate update uses guest validation
- **WHEN** an upstream sync affects Redox-native packages, vendored guest source bundles, or self-hosting build inputs
- **THEN** the change runs focused VM or self-hosting validation in addition to host checks
