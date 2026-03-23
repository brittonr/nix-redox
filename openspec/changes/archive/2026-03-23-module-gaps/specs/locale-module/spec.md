## ADDED Requirements

### Requirement: Locale module provides LANG and LC_* options
The system provides a `/locale` module at `nix/redox-system/modules/locale.nix` with options for `LANG`, `LC_ALL`, and per-category locale variables (`LC_COLLATE`, `LC_CTYPE`, `LC_MESSAGES`, `LC_MONETARY`, `LC_NUMERIC`, `LC_TIME`).

#### Scenario: Default locale is C
- **WHEN** no profile configures `/locale`
- **THEN** `LANG` defaults to `"C"` and no `LC_*` overrides are set

#### Scenario: Custom LANG
- **WHEN** a profile sets `/locale.lang = "en_US.UTF-8"`
- **THEN** `LANG=en_US.UTF-8` appears in `/etc/profile` and in the ion `initrc`

### Requirement: Locale variables appear in generated environment files
The build pipeline emits locale variables into both `/etc/profile` (for POSIX shells) and `/etc/ion/initrc` (for Ion shell sessions).

#### Scenario: Profile with locale set
- **WHEN** `/locale.lang = "en_US.UTF-8"` and `/locale.lcTime = "C"`
- **THEN** `/etc/profile` contains `export LANG en_US.UTF-8` and `export LC_TIME C`
- **AND** `/etc/ion/initrc` contains `let LANG = "en_US.UTF-8"` and `export LANG`

#### Scenario: LC_ALL overrides categories
- **WHEN** `/locale.lcAll = "C"`
- **THEN** `LC_ALL=C` appears in both profile and initrc, regardless of individual `LC_*` values

### Requirement: Locale is environment-only
The module sets environment variables. It does not install locale data files or modify relibc behavior. The module description documents this limitation.

#### Scenario: No locale data files
- **WHEN** any locale configuration is set
- **THEN** no files are added under `/usr/share/locale/` or similar paths
