## ADDED Requirements

### Requirement: Self-hosting patch inventory is explicit and current

The repo SHALL maintain an explicit inventory of all self-hosting patches applied to relibc, cargo, rustc, llvm/lld wrappers, and related build inputs. Each entry SHALL record the patch location, owning subsystem, owner or owning area, protected behavior, the runtime symptom or build failure it prevents, upstream status, expected removal risk, fallback plan, and the focused and broad validation gates that cover removal.

#### Scenario: Inventory answers why a patch exists
- **WHEN** a developer inspects a patch applied in the self-hosting toolchain pipeline
- **THEN** the inventory identifies the runtime symptom or build failure the patch protects
- **AND** records the owner or owning area, expected removal risk, and fallback plan for that patch
- **AND** points to the focused and broad validation gates for that patch

#### Scenario: Inventory stays in sync with patch application
- **WHEN** a patch is added, removed, or renamed in the build pipeline
- **THEN** the inventory is updated in the same change
- **AND** the inventory does not contain stale entries for patches no longer applied

### Requirement: Patch retirement uses one-patch-at-a-time validation

Candidate patch removals SHALL run the focused validation mapped to that patch class before the change is accepted, followed by the broader self-hosting gate required for that subsystem.

#### Scenario: Focused validation catches a still-required patch
- **WHEN** a developer removes a patch whose protected behavior is still broken
- **THEN** the mapped focused validation fails and identifies the regression
- **AND** the patch removal is not kept silently

#### Scenario: Low-risk patch retires cleanly
- **WHEN** a developer removes an obsolete patch
- **AND** the mapped focused validation passes
- **AND** the broader self-hosting gate also passes
- **THEN** the patch remains removed
- **AND** the inventory records the retirement

### Requirement: Remaining patches carry blocker evidence and next action

If a patch cannot be retired yet, the inventory SHALL record current blocker evidence and the next condition that should trigger re-testing or upstream work.

#### Scenario: Patch blocked on upstream or missing kernel support
- **WHEN** a patch remains necessary after validation
- **THEN** the inventory records the failing behavior or missing prerequisite
- **AND** names the next action as upstream submission, redesign, or a future re-test trigger
