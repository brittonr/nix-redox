## Context

The repo carries many patches because Redox self-hosting reached functionality by fixing real blockers in place. That was correct for enablement, but the current state makes it hard to answer basic maintenance questions: which patches are still required, which ones are already obsolete, which tests prove necessity, and which ones are realistic upstream candidates. Toolchain bumps now risk rediscovering the same answers by hand.

## Goals / Non-Goals

**Goals:**
- Produce a living inventory of every self-hosting patch and the behavior it protects.
- Tie each patch class to focused validation so removals become cheap and reversible.
- Retire at least the low-risk, already-obsolete patches or explicitly mark them blocked with evidence.

**Non-Goals:**
- Upstream every remaining patch in one cycle.
- Re-architect the toolchain from scratch.
- Replace deep technical fixes with purely process documentation.

## Decisions

### 1. Treat patch reduction as an inventory + validation problem first

**Choice:** Start by making every patch visible with metadata: subsystem, symptom, owner, upstream status, expected removal test, and fallback plan.

**Rationale:** The main friction today is not only patch count; it is uncertainty. Inventory first makes every later removal mechanical instead of exploratory.

**Alternative considered:** Try to delete patches opportunistically during unrelated work. Rejected because it keeps rediscovering context and mixes removal failures into unrelated changes.

### 2. Remove patches one class at a time with explicit validation gates

**Choice:** Every candidate removal will define the smallest focused validation that should fail before the patch and pass without it after the fix lands, plus the broader self-hosting gate required before keeping the removal.

**Rationale:** Toolchain failures are often late and noisy. A focused gate lowers iteration time and tells us what the patch actually protects.

**Alternative considered:** Remove multiple patches in one batch. Rejected because failure attribution becomes ambiguous immediately.

### 3. Keep blocked patches, but require blocker evidence

**Choice:** Patches that cannot be retired yet remain allowed only if they carry current blocker evidence and a next action (upstream, redesign, or re-test trigger).

**Rationale:** Some patches are still real. The goal is not fake reduction; it is a truthful, maintainable patch surface.

**Alternative considered:** Forcing removal of every patch to hit a number target. Rejected because it would break the working self-hosting baseline.

## Risks / Trade-offs

- **Inventory goes stale** → Store patch metadata close to the patch application site and make it part of validation updates.
- **Focused tests miss interactions** → Pair focused validation with a broader self-hosting gate before final removal.
- **Some patches span multiple symptoms** → Allow one patch to map to multiple gates, but require the primary protected behavior to be named explicitly.

## Migration Plan

1. Build the initial inventory from current patch pipelines.
2. Attach each patch to focused and broad validation gates.
3. Attempt low-risk removals first.
4. Leave blocker notes and upstream next steps for patches that remain.

## Open Questions

- Whether the patch inventory should live as structured data, generated markdown, or both.
- Which existing VM tests are still too coarse and need focused companions before safe patch retirement.
