## ADDED Requirements

### Requirement: Console module controls text-mode display settings
The system provides a `/console` module at `nix/redox-system/modules/console.nix` with options for the framebuffer console VT number, inputd enable flag, and boot log display.

#### Scenario: Default VT assignment
- **WHEN** no profile configures `/console`
- **THEN** `fbcond` uses VT 2, `inputd` uses VT 1, matching current hardcoded behavior

#### Scenario: Custom fbcond VT
- **WHEN** a profile sets `/console.fbcondVT = 4`
- **THEN** the generated `20_graphics` initfs script passes VT 4 to `fbcond` instead of VT 2

### Requirement: Console can be disabled independently
Individual console components (fbcond, inputd, fbbootlogd) can be disabled without affecting other initfs daemons.

#### Scenario: Disable boot log display
- **WHEN** `/console.bootLog = false`
- **THEN** `fbbootlogd` is not started in the initfs init scripts

#### Scenario: Disable inputd
- **WHEN** `/console.inputd = false`
- **THEN** `inputd` is not started and its VT line is omitted from the initfs script

### Requirement: Console settings only apply when graphics hardware is present
The console module options only affect init script generation when `boot.initfsEnableGraphics` (or `graphics.enable`) is true. Without graphics hardware, the options are ignored.

#### Scenario: Headless system ignores console config
- **WHEN** `/console.fbcondVT = 5` but `/graphics.enable = false` and `/boot.initfsEnableGraphics = false`
- **THEN** the `20_graphics` initfs script is empty and no fbcond/inputd daemons start

### Requirement: Console module integrates with initfs script generation
The `init-scripts.nix` file reads console module options to template the `20_graphics` initfs script instead of using hardcoded VT numbers.

#### Scenario: Generated initfs script uses module values
- **WHEN** `/console.fbcondVT = 3` and `/console.inputdVT = 2`
- **THEN** the `20_graphics` script contains `scheme fbcon fbcond 3` and `inputd -A 2`
