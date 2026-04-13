## 1. Build the patch inventory

- [ ] 1.1 Enumerate every self-hosting patch applied to relibc, cargo, rustc, llvm/lld wrappers, and related build inputs.
- [ ] 1.2 Record for each patch: subsystem, protected behavior, upstream status, expected removal risk, and fallback plan.
- [ ] 1.3 Publish the inventory in a repo location that stays close to the patch application points.

## 2. Map validation to each patch class

- [ ] 2.1 Define the smallest focused validation that should detect each patch's protected behavior.
- [ ] 2.2 Map each patch class to the broader suite gate required before keeping a removal.
- [ ] 2.3 Fill obvious test gaps where a patch has no focused validation today.

## 3. Retire low-risk obsolete patches

- [ ] 3.1 Select an initial batch of low-risk candidates with clear validation coverage.
- [ ] 3.2 Remove each candidate one at a time and run the mapped focused + broad validation.
- [ ] 3.3 Keep the removals that pass and restore any patch whose validation still proves it necessary.

## 4. Record blockers and next actions

- [ ] 4.1 For each remaining patch, capture current blocker evidence and the condition that would justify re-testing removal.
- [ ] 4.2 Mark patches that are strong upstream candidates versus Redox-specific long-tail workarounds.
- [ ] 4.3 Update self-hosting docs to point at the patch inventory instead of scattered tribal knowledge.
