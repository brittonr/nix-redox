## Context

Self-hosting runs are long, expensive, and easy to lose if they only live in pueue output or a transient terminal scrollback. The repo already started moving toward durable capture directories, host monitor logs, and archived excerpts, but the behavior is not yet fully standardized. We should make proof artifact generation automatic and uniform across focused and full validation commands.

## Goals / Non-Goals

**Goals:**
- Standardize the capture layout for important self-hosting validation runs.
- Emit machine-readable summaries that can be diffed or indexed later.
- Make the wrappers create those artifacts automatically so future evidence is cheap.

**Non-Goals:**
- Replace the underlying tests themselves.
- Build a large dashboard system in this change.
- Archive every exploratory run forever.

## Decisions

### 1. Define one capture contract for focused and full runs

**Choice:** Every important self-hosting validation wrapper will create the same timestamped run directory with metadata, logs, summary JSON, and excerpt text.

**Rationale:** Uniformity matters more than feature richness. Readers should not have to guess where a run stored its proof.

**Alternative considered:** Let each wrapper emit whatever logs it finds convenient. Rejected because that recreates the current artifact sprawl.

### 2. Emit machine-readable and human-readable outputs together

**Choice:** Each run will produce both a compact JSON summary and a short text excerpt suitable for notes or archive references.

**Rationale:** JSON is good for indexing and automation; excerpts are good for humans and change evidence.

**Alternative considered:** Keep only raw logs. Rejected because it still forces every later session to mine the same details manually.

### 3. Keep an explicit latest-success index

**Choice:** Record which capture directory is the latest known success for each major validation flow.

**Rationale:** Roadmap and docs should reference concrete artifacts, not prose claims detached from the underlying run.

**Alternative considered:** Keep success references only in AGENTS or session notes. Rejected because those are easy to drift.

## Risks / Trade-offs

- **Artifact volume grows quickly** → Restrict automatic capture to focused/full proof flows, not every exploratory test.
- **Wrappers diverge over time** → Share helper code or a common script for capture creation and summary generation.
- **People still cite stale captures** → Maintain the latest-success index and update docs to point at it.

## Migration Plan

1. Define the capture contract and file set.
2. Update focused/full wrappers to create it automatically.
3. Generate summaries/excerpts from real runs.
4. Add an index of latest successful proofs and update docs to use it.

## Open Questions

- Whether the index should be checked into the repo or generated from the capture directory tree.
- Which exploratory runs, if any, should opt into the same artifact contract.
