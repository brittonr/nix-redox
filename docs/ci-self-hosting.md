# Self-hosting CI

`.github/workflows/self-hosting.yml` has two gates.

## Evidence replay (hosted, always runs)

The `Evidence replay / video` job runs on `ubuntu-latest` for every push and
pull request. It renders `docs/assets/demo/nix-redox-self-build.mp4` from the
committed fixture at `demo/fixtures/native-rebuild-test/`, then asserts that
the cast contains the seed, native, and rollback phases and the `134/134`
result.

This validates the video renderer and the checked-in evidence. It does **not**
rebuild Redox.

## Native rebuild proof (KVM runner)

The `Native rebuild proof (KVM)` job is the live proof. It runs
`nix run .#native-rebuild-test`, validates the capture summary, and uploads the
capture artifacts.

Standard GitHub-hosted runners do not expose `/dev/kvm`. This job therefore
targets a self-hosted runner with the labels:

```
self-hosted, linux, x64, redox-kvm
```

The runner needs:

- x86_64 Linux with Nix flakes
- `/dev/kvm` access
- at least 4 vCPUs, 8 GiB RAM, and 20 GiB free disk
- no display; the proof is headless

## Enabling the live gate

1. Register a trusted runner with the labels above.
2. Enable the repository variable:

   ```bash
   gh variable set KVM_PROOF_ENABLED --body true
   ```

3. Trigger the workflow once:

   ```bash
   gh workflow run self-hosting.yml
   ```

The live job then runs on `main` pushes and manual dispatches. It is skipped
while the variable is unset, so repositories without a KVM runner keep a green
hosted evidence gate.

## Security and branch protection

This repository is public. **Do not attach a persistent self-hosted runner to
untrusted pull requests.** A self-hosted runner executes repository code with
the runner user's permissions and must be treated as a trusted machine.

Safe options:

- Run the live job on `main` and release tags only, as configured here.
- Use an ephemeral, disposal runner per job for pull-request proof.
- Require a protected GitHub environment with manual approval before the KVM
  job.

Require the hosted check for pull requests:

- Required check: `Self-hosting proof / Evidence replay / video`

If a trusted, isolated KVM runner is available for pull requests, add the live
check as well:

- Required check: `Self-hosting proof / Native rebuild proof (KVM)`

A required check that can run untrusted PR code on shared infrastructure is not
acceptable for this public repository.
