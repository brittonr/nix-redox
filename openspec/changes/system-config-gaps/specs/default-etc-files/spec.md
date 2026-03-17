## default-etc-files

Standard /etc files that upstream Redox programs expect.

### Requirements

- [REQ-MOTD] `/etc/motd` is generated with a default welcome message.
  The text is configurable via the environment module's `etc` option.
  The default text is "Welcome to Redox OS!".

- [REQ-SHELLS] `/etc/shells` is generated listing valid login shells.
  At minimum: `/bin/ion` and `/bin/sh`. If bash is in systemPackages,
  also list `/bin/bash`.

### Tests

- Artifact test: default rootTree contains `/etc/motd` with
  "Welcome to Redox OS!".
- Artifact test: default rootTree contains `/etc/shells` with
  `/bin/ion`.
- Artifact test: rootTree with custom motd via environment.etc
  contains the custom text instead.
