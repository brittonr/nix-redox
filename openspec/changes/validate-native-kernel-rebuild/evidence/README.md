# validate-native-kernel-rebuild evidence

Passing focused proof run:
- run: `20260414T230502-kernel-rebuild-test`
- commit: `ea2921a9`
- capture: `/var/tmp/redox-self-hosting-captures/20260414T230502-kernel-rebuild-test`
- excerpt: `2026-04-14-kernel-rebuild-test.excerpt.txt`
- summary: `2026-04-14-kernel-rebuild-test.summary.json`

What this proves:
- Redox guest rebuilt the kernel natively and produced `/nix/store/0yiqaj311cni1rqqyqzc9pln2h3w6rss-redox-kernel-native-rebuild`.
- Redox guest rebuilt the bootloader natively and produced `/nix/store/06x25abzqs38pyscj58vssf9z9p1gv1n-redox-bootloader-native-rebuild`.
- The focused flow switched to a manifest referencing those guest-produced paths, verified the saved generation manifest / boot-default marker / GC roots, and proved the kernel artifact was staged into both `/boot/kernel` and `usr/lib/boot/kernel`.
- The focused flow then used `snix system boot` plus `snix system activate-boot` to simulate next-boot generation selection and re-activate the staged guest-produced kernel path without creating a new generation.

Still out of scope for this change:
- a firmware-level reboot of the same VM that loads the guest-produced bootloader from the ESP
