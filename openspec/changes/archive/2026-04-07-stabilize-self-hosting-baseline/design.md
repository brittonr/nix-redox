## Context

There are two different kinds of self-hosting work in flight:

1. stabilization work needed to prove the current `snix` implementation works on Redox
2. expansion work that adds new capabilities after the baseline is trustworthy

Right now those are mixed together.

`fix-snix-build-gaps` already captured the short list of remaining validation failures, but its task text still assumes the per-path proxy sandbox is the active environment. That is no longer true after `70b70d74`, which disables the proxy and uses scheme-only sandboxing. A fresh `self-hosting-test` run is therefore a prerequisite for any honest prioritization.

At the same time, `nix-self-hosting-roadmap` is too broad to serve as the next concrete plan. Remote cache, store scheme, rebuild generations, and rollback are worthwhile, but they should not move ahead while the current flake/build/rebuild baseline is stale.

## Goals / Non-Goals

**Goals**
- establish a fresh, completed self-hosting baseline after the sandbox rollback
- fix small correctness issues in the flake/build path that distort validation
- update the active self-hosting changes so the next implementation work is sequenced clearly
- keep the next self-hosting milestone narrow enough to finish

**Non-Goals**
- implement remote cache transport
- implement `stored`
- implement generation management or rollback
- solve hardware or networking issues
- merge or archive unrelated OpenSpec changes

## Decisions

### 1. Split self-hosting into Phase 1 stabilization and Phase 2 expansion

**Choice:** treat stabilization as a separate milestone that must complete before roadmap expansion resumes.

**Rationale:** the project already has evidence that large self-hosting features can exist in code before they are validated on a real guest. Mixing new feature work with stale validation makes every failure harder to classify.

**Alternative:** continue working directly from `nix-self-hosting-roadmap`.

That was rejected because it mixes baseline validation with new feature delivery and encourages work on phase-two items before the current build path is trustworthy.

**Implementation:** create a dedicated change that rebaselines the self-hosting suite, fixes the most obvious build-path issues, and updates the older changes to reflect the new order.

### 2. Use a completed `self-hosting-test` run as the entry criterion

**Choice:** require a completed `nix run .#self-hosting-test` run before reclassifying the remaining work.

**Rationale:** current task state still reflects proxy-era failures. The post-rollback world may have a smaller or different failure set. We should not guess.

**Alternative:** infer the new baseline from code review alone.

That was rejected because it would still leave the failure inventory stale.

**Implementation:** let the current run finish or re-run it if needed, then record pass/fail/timeout results and update `fix-snix-build-gaps` from those results.

### 3. Fix the flake path before resuming broad guest validation

**Choice:** treat flake option parity and forge URL correctness as stabilization blockers.

**Rationale:** flake installables are already part of the self-hosting story. If they bypass `--no-sandbox` or generate invalid GitLab tarball URLs, the test suite gives misleading results.

**Alternative:** defer these to later because they are small bugs.

That was rejected because they affect the correctness of the validation harness itself.

**Implementation:** patch `snix-redox/src/flake.rs`, `snix-redox/src/main.rs`, and the related tests before using flake results to declare the baseline stable.

### 4. Remove stale proxy-specific assumptions from active self-hosting work

**Choice:** rewrite remaining tasks and comments so they describe scheme-only sandboxing as the current mode.

**Rationale:** stale task text wastes time. It sends future work back into dead proxy debugging even though the proxy is disabled.

**Alternative:** leave the old text in place and rely on tribal knowledge.

That was rejected because this repo already uses OpenSpec to preserve hard-won context.

**Implementation:** update `fix-snix-build-gaps` after the first completed baseline run and keep the proxy work explicitly deferred to a later kernel-dependent change.

## Risks / Trade-offs

**Long validation cycles** -> Host cache failures or large rebuilds can stretch `self-hosting-test` runs. Mitigation: separate host-build infrastructure failures from guest test failures in the recorded baseline.

**Scope creep back into roadmap work** -> Remote cache, `stored`, and generation work are tempting to start early. Mitigation: define explicit stabilization exit criteria and treat phase-two work as blocked until they are met.

**Overfitting tasks to one transient run** -> One run may include incidental infra noise. Mitigation: capture both the raw run result and a cleaned classification of correctness bugs vs. timeouts vs. host-cache noise.

## Exit Criteria

Phase 1 stabilization is complete when all of these are true:

- a full `self-hosting-test` run completes under the current scheme-only sandbox model
- the remaining failures are classified and reflected in `fix-snix-build-gaps`
- flake installables honor the same sandbox-control path as other local builds
- GitLab forge tarball URLs are verified by unit tests
- `nix-self-hosting-roadmap` is updated to depend on the stabilized baseline instead of running in parallel with it
