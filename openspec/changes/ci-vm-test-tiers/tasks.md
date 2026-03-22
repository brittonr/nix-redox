## 1. Wire new tests into checks.nix

- [x] 1.1 Add fast-tier tests to vmChecks: scheme-daemon-test, iroh-test, scheme-native-test, boot-generation-select-test
- [x] 1.2 Add full-tier tests to vmChecks: rebuild-generations-test, e2e-rebuild-test, network-test, network-install-test, channel-update-test
- [x] 1.3 Add heavy-tier tests to vmChecks: bridge-rebuild-test, self-hosting-test, parallel-build-test

## 2. Restructure tier aggregation

- [x] 2.1 Split vmChecks into vmChecksFast, vmChecksFull, vmChecksHeavy attribute sets
- [x] 2.2 Create tier-vm-fast, tier-vm-full, tier-vm-heavy aggregation targets using mkTierCheck (each cumulative — full includes fast, heavy includes full)
- [x] 2.3 Create tier-vm-all that depends on all three sub-tiers
- [x] 2.4 Alias tier-vm to tier-vm-fast for backward compatibility

## 3. Verify

- [x] 3.1 Run `nix eval` to confirm all new check attributes resolve without errors
- [x] 3.2 Run `nix build .#checks.x86_64-linux.tier-vm-fast` — all 8 tests pass
- [x] 3.3 Spot-check one new full-tier test: `nix build .#checks.x86_64-linux.network-test`
