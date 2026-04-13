## Context

The repo already documents many sharp edges for C/C++ builds on Redox: `cc-rs` needs the right wrapper and `AR`, autotools probes dislike `-nostdlib`, cmake flag placement matters, and individual packages like OpenSSL/OpenSSH need Redox-specific adjustments. Those lessons are valuable, but they are spread across AGENTS notes and isolated package work. We need a validation shape that turns those lessons into a standing contract.

## Goals / Non-Goals

**Goals:**
- Create a small but representative guest-native gauntlet for C and C++ package builds.
- Surface wrapper/sysroot/linker failures with actionable diagnostics.
- Use the gauntlet as the regression gate for future wrapper or packaging changes.

**Non-Goals:**
- Prove every upstream C/C++ package builds on Redox.
- Eliminate all package-specific workarounds in one change.
- Replace existing Rust-focused self-hosting validation.

## Decisions

### 1. Cover build-system classes, not package popularity

**Choice:** Pick a few fixtures that represent failure classes: `cc-rs`, autotools C, and cmake/C++.

**Rationale:** We care about wrapper and ecosystem coverage more than bragging about specific names. One package per class is enough to catch structural regressions.

**Alternative considered:** Start with a long package list. Rejected because it increases noise before we know which classes are missing coverage.

### 2. Put diagnostic capture in the harness, not only in package logs

**Choice:** The guest harness will capture wrapper commands, failing compiler/linker invocations, and relevant environment details when a gauntlet stage fails.

**Rationale:** C/C++ failures are often buried in configure or build-system output. Capturing the right context centrally shortens iteration time.

**Alternative considered:** Tell developers to inspect package logs manually. Rejected because it repeats the same slow failure-analysis loop.

### 3. Gate wrapper and sysroot changes on the gauntlet

**Choice:** Changes to `cc`, clang resource-dir handling, linker flags, sandbox allow-lists, or sysroot packaging should run the gauntlet before landing.

**Rationale:** Those are exactly the changes that tend to break non-Rust packages first.

**Alternative considered:** Keep the gauntlet informational only. Rejected because it would not prevent regressions.

## Risks / Trade-offs

- **Fixtures become too package-specific** → Choose small representative fixtures and document why each one exists.
- **Guest runtime gets long** → Keep the first gauntlet intentionally small and focused.
- **Diagnostics become noisy** → Capture a fixed set of wrapper/env/linker details instead of dumping everything.

## Migration Plan

1. Select representative packages/fixtures.
2. Add harness-side diagnostics.
3. Run the gauntlet and fix current blockers.
4. Treat it as the standing gate for future wrapper/sysroot work.

## Open Questions

- Which concrete autotools and cmake fixtures are the smallest useful representatives in this tree.
- Whether one combined gauntlet or separate focused tests give the best turnaround time.
