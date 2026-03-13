## 1. Fix profiled execution test

- [x] 1.1 Replace `rg-from-profile-works` test to execute rg via store path instead of filesystem profile path
- [x] 1.2 Add `store-scheme-file-read` test that reads rg binary bytes through `/scheme/store/` and verifies size > 0
- [x] 1.3 Add comment explaining scheme-vs-filesystem distinction for profile paths
- [x] 1.4 Build and run scheme-native test — 22/22 PASS, 0 FAIL, 0 SKIP (was 20 pass + 1 skip)

## 2. Investigate --env-set workaround

- [x] 2.1 Validated 2026-03-11 via fix-remaining-os-bugs task 2.7: built cargo without patch-cargo-env-set.py, ran full self-hosting test. buildrs test shows option_env!("BUILD_TARGET") returns None (env=missing). Confirms env propagation still broken without --env-set.
- [x] 2.2 Done via fix-remaining-os-bugs task 2.7: 42 pass, 8 fail (5 pre-existing heredoc issues, 1 parallel-jobs, 2 heredoc-related). --env-set patch confirmed still necessary.
- [x] 2.3 Document findings: which specific env vars fail, in which crate context (proc-macro vs binary), and root cause hypothesis
- [x] 2.4 Based on findings, either remove the workaround (if all tests pass) or add permanent documentation comment in rustc-redox.nix — KEPT with expanded permanent rationale

## 3. Update README

- [x] 3.1 Rewrite README.md with sections for: Quick Start, What's in the Image, Running, Building, Module System, snix (Nix on Redox), Self-Hosting, Build Bridge, Testing, Development, Architecture, Credits
- [x] 3.2 Add snix section covering eval, build, install, store/profile daemons, flake installables, network cache
- [x] 3.3 Add self-hosting section covering cargo/rustc on Redox, proc-macros, build scripts, known limits
- [x] 3.4 Add build bridge section with virtio-fs commands and workflow
- [x] 3.5 Update test counts and testing section with current numbers
- [x] 3.6 Update package table and running modes to reflect current state
