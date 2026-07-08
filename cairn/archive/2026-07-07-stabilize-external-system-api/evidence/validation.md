# Validation evidence

Implementation evidence for `stabilize-external-system-api`.

## Baseline

- `nix build .#checks.x86_64-linux.tier-eval --no-link -L`
  - Result: passed before substrate changes.
  - Evidence excerpt: task completed successfully after building the tier-eval check.

## Focused substrate checks

- `nix eval .#legacyPackages.x86_64-linux.redoxSubstrate.manifest.schema`
  - Result: `"redox-substrate-v1"`.

- `nix eval --json .#legacyPackages.x86_64-linux.redoxSubstrate.manifest >/dev/null`
  - Result: passed; manifest is data-only JSON-serializable.

- `nix build .#checks.x86_64-linux.substrate-manifest-public-surface .#checks.x86_64-linux.substrate-primitive-plan-normalizes --no-link -L`
  - Result: passed.
  - Evidence excerpt: `Test PASSED: manifest-public-surface`; `Test PASSED: primitive-plan-normalizes`.

- `nix build .#checks.x86_64-linux.substrate-fixture-builds-from-public-surface .#checks.x86_64-linux.substrate-rejects-malformed-service-argv .#checks.x86_64-linux.substrate-rejects-unsupported-networking-field .#checks.x86_64-linux.substrate-rejects-missing-ingredient .#checks.x86_64-linux.substrate-rejects-conflicting-filesystem-entry .#checks.x86_64-linux.substrate-rejects-private-consumer-import --no-link -L`
  - Result: passed.
  - Evidence excerpt: `Test PASSED: fixture-builds-from-public-surface`; service file preserved `args = ["--flag","value with spaces"]`.

## Aggregate after changes

- `nix build .#checks.x86_64-linux.tier-eval --no-link -L`
  - Result: passed after substrate changes.

## Cairn gates

- `cairn validate --root . --policy /home/brittonr/git/OnixResearch/cairn/cairn-policy/generated/cairn-policy.json`
- `cairn gate proposal stabilize-external-system-api --root . --policy /home/brittonr/git/OnixResearch/cairn/cairn-policy/generated/cairn-policy.json`
- `cairn gate design stabilize-external-system-api --root . --policy /home/brittonr/git/OnixResearch/cairn/cairn-policy/generated/cairn-policy.json`
- `cairn gate tasks stabilize-external-system-api --root . --policy /home/brittonr/git/OnixResearch/cairn/cairn-policy/generated/cairn-policy.json`
  - Result: passed before implementation.
