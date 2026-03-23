## Why

Three module system gaps prevent correct system configuration:

1. **Audio is locked behind graphics.** The `audiod` service is computed inside `graphics.nix` and only starts when `graphics.enable = true`. A headless server that plays audio notifications or a CI system that tests audio drivers cannot enable audio without pulling in Orbital. Audio and graphics are independent subsystems that should be independently controllable.

2. **No locale configuration.** There is no module for `LANG`, `LC_ALL`, or any i18n variables. Every system defaults to the C locale with no way to change it. Programs that check locale (libc, Rust's `std::env`, any ported POSIX software) get no signal about the intended locale.

3. **Console is not configurable.** The text-mode console (`fbcond`, `inputd`, VT assignments) is hardcoded in the initfs init scripts. There is no way to change the console VT number, disable the framebuffer console, or configure input without overriding raw initfs scripts.

## What Changes

- Extract `audiod` service from `graphics.nix` into a new `audio.nix` module with its own `enable` flag, independent of `graphics.enable`.
- Add a new `locale.nix` module with `LANG`, `LC_ALL`, and `LC_*` category overrides. Wire into `/etc/profile` and ion `initrc` generation.
- Add a new `console.nix` module for text-mode console settings: VT number for `fbcond`, enable/disable `inputd`, and the `fbbootlogd` boot log display.
- Update `build/config.nix` and `build/init-scripts.nix` to consume the new modules.
- Update `build/generated-files.nix` to emit locale variables.
- Update graphical profile to enable both `graphics` and `audio` (preserving current behavior).

## Capabilities

### New Capabilities
- `audio-module`: Standalone audio module that controls audiod and audio driver loading independently of graphics.
- `locale-module`: Locale configuration module providing LANG, LC_ALL, and per-category LC_* overrides.
- `console-module`: Text-mode console module controlling fbcond VT, inputd, and boot log display.

### Modified Capabilities

## Impact

- `nix/redox-system/modules/graphics.nix` — remove audiod service generation
- `nix/redox-system/modules/build/config.nix` — add inputs for audio, locale, console
- `nix/redox-system/modules/build/init-scripts.nix` — consume audio.services and console options for initfs scripts
- `nix/redox-system/modules/build/generated-files.nix` — emit locale env vars in profile and initrc
- `nix/redox-system/modules/build/default.nix` — add new module inputs
- `nix/redox-system/profiles/graphical.nix` — set `/audio.enable = true` alongside `/graphics.enable = true`
- All test profiles that use graphics: verify they still pass with audio decoupled
