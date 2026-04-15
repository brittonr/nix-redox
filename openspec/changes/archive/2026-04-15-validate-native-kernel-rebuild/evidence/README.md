# validate-native-kernel-rebuild evidence

Host-side activation unit tests:
- command: `PROTO_ROOT=$PWD/upstream PROTOC=$(nix shell nixpkgs#protobuf --command which protoc | tail -n1) cargo test --lib --target x86_64-unknown-linux-gnu boot_update_ -- --nocapture`
- evidence: `2026-04-15-activate-unit-tests.txt`
- result: `5 passed, 0 failed`
- includes: `boot_update_requires_active_boot_copy`, which proves `/boot/*` success alone no longer reports boot artifact update success when `/usr/lib/boot/*` refresh fails.

Passing focused proof run:
- run: `20260415T000324-kernel-rebuild-test`
- commit: `af057438`
- capture: `/var/tmp/redox-self-hosting-captures/20260415T000324-kernel-rebuild-test`
- excerpt: `2026-04-14-kernel-rebuild-test.excerpt.txt`
- summary: `2026-04-14-kernel-rebuild-test.summary.json`

What this proves:
- Redox guest rebuilt the kernel natively and produced `/nix/store/0yiqaj311cni1rqqyqzc9pln2h3w6rss-redox-kernel-native-rebuild`.
- Redox guest rebuilt the bootloader natively and produced `/nix/store/06x25abzqs38pyscj58vssf9z9p1gv1n-redox-bootloader-native-rebuild`.
- The focused flow switched to a manifest referencing those guest-produced paths, verified the saved generation manifest / boot-default marker / GC roots, and proved the kernel artifact was staged into both `/boot/kernel` and `usr/lib/boot/kernel`.
- The focused flow then used `snix system boot` plus `snix system activate-boot` to simulate next-boot generation selection and re-activate the staged guest-produced kernel path without creating a new generation.

Still out of scope for this change:
- a firmware-level reboot of the same VM that loads the guest-produced bootloader from the ESP
