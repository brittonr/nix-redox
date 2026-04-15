# validate-native-kernel-rebuild evidence

Passing focused proof run:
- run: `20260414T205052-kernel-rebuild-test`
- commit: `96f1857b`
- capture: `/var/tmp/redox-self-hosting-captures/20260414T205052-kernel-rebuild-test`
- excerpt: `2026-04-14-kernel-rebuild-test.excerpt.txt`
- summary: `2026-04-14-kernel-rebuild-test.summary.json`

What this proves:
- Redox guest rebuilt the kernel natively and produced `/nix/store/0yiqaj311cni1rqqyqzc9pln2h3w6rss-redox-kernel-native-rebuild`.
- Redox guest rebuilt the bootloader natively and produced `/nix/store/06x25abzqs38pyscj58vssf9z9p1gv1n-redox-bootloader-native-rebuild`.
- Durable capture output recorded bundle provenance, guest verdicts, and pathinfo for both artifacts.

Still out of scope for this change:
- staging those guest-produced artifacts into boot selection / manifest plumbing
- reboot smoke proving the VM actually boots the guest-produced kernel + bootloader
