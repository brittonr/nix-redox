# Self-Hosting Baseline Specification

## Purpose

Define the immediate self-hosting stabilization requirements that must be met before the broader self-hosting roadmap expands into remote cache, store-scheme, and generation-management work.

## ADDED Requirements

### Requirement: Completed self-hosting baseline after major build-path changes

The project MUST establish a fresh self-hosting validation baseline from a completed `self-hosting-test` run after any major `snix` build-path change that affects sandboxing, builder execution, or flake evaluation.

#### Scenario: Scheme-only sandbox rebaseline

- GIVEN the build pipeline has changed from proxy sandboxing to scheme-only sandboxing
- WHEN the next self-hosting milestone is planned
- THEN a completed `self-hosting-test` run SHALL be recorded before new self-hosting feature work is treated as in scope
- AND the resulting failures SHALL be classified as correctness bugs, timeouts, or host-infrastructure noise

### Requirement: Flake build option parity

All local `snix build` entry points MUST honor the same sandbox-control behavior, including flake installables.

#### Scenario: Flake installable with no-sandbox

- GIVEN a user runs `snix build --no-sandbox .#hello`
- WHEN the flake installable is evaluated and built
- THEN the build SHALL use the same no-sandbox local-build path as `snix build --no-sandbox --file ...`
- AND the result SHALL not depend on a separate hard-coded build path for flakes

### Requirement: Forge archive URL correctness for locked flake inputs

Locked GitHub and GitLab flake inputs MUST resolve to valid archive URLs before guest validation treats fetch failures as Redox-side bugs.

#### Scenario: GitLab https URL

- GIVEN a locked git input with URL `https://gitlab.redox-os.org/redox-os/relibc.git`
- WHEN `snix` derives a forge tarball URL for that input
- THEN the URL SHALL be `https://gitlab.redox-os.org/redox-os/relibc/-/archive/<rev>/relibc-<rev>.tar.gz`
- AND the scheme and host SHALL not be malformed by the conversion

### Requirement: Expansion roadmap gated on stabilized baseline

The broader self-hosting roadmap SHALL defer remote cache, store-scheme, generation-management, and rollback work until the stabilization baseline is complete.

#### Scenario: Baseline still incomplete

- GIVEN the latest completed self-hosting baseline still has unclassified failures or stale tasks
- WHEN planning work for the next self-hosting session
- THEN stabilization work SHALL be prioritized ahead of remote cache, `stored`, or generation-management implementation
- AND the roadmap tasks for those phase-two features SHALL remain explicitly blocked on the stabilization exit criteria
