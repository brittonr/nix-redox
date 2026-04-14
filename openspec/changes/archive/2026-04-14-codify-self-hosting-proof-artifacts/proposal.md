## Why

The repo already has strong self-hosting evidence, but much of it lives in notes, pueue logs, and manually curated excerpts. That is enough for one session and not enough for a durable claim. The next improvement is to make every important self-hosting validation run leave the same capture layout, summary artifacts, and index entries by default.

## What Changes

- Standardize a timestamped capture directory layout for self-hosting validation runs.
- Emit a machine-readable summary and a short human excerpt for each run.
- Add tooling or wrappers so focused and full self-hosting validations create those artifacts automatically.
- Keep an index of the latest successful captures that roadmap and docs can reference directly.

## Capabilities

### New Capabilities
- `self-hosting-proof-artifacts`: Make self-hosting claims rest on durable, uniform capture artifacts instead of ad hoc logs.

### Modified Capabilities

None.

## Impact

- **Validation wrappers**: self-hosting-focused and full-suite entry points.
- **Artifacts**: capture directory layout, summary JSON, excerpt text, metadata, and indexing.
- **Docs/roadmap**: easier references to latest successful proof runs.
- **Reviewability**: future sessions can inspect the exact run artifacts without depending on ephemeral task logs.
