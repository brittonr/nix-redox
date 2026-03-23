## Context

The adios module system has 19 modules covering boot, environment, filesystem, graphics, hardware, networking, etc. Three subsystems lack proper module coverage:

- Audio is coupled to graphics — the `audiod` service is computed inside `graphics.nix` and gated on `graphics.enable`. Audio drivers load via `hardware.audioEnable` but the daemon never starts without Orbital.
- Locale has no module — LANG/LC_* are never set.
- Console (fbcond/inputd) is hardcoded in initfs init scripts with no configuration surface.

Each module follows the adios pattern: define options with korora types, export via `impl = { options }: options;`, and get consumed by `build/config.nix` → `build/init-scripts.nix` → `build/generated-files.nix`.

## Goals / Non-Goals

**Goals:**
- Audio can be enabled independently of graphics (`/audio.enable = true` without `/graphics.enable = true`)
- Locale variables appear in `/etc/profile` and ion `initrc` when configured
- Console VT number and enable flags are configurable via module options
- Existing profiles (graphical, development, minimal) produce identical output after the change
- New modules follow the same adios patterns as existing modules (korora types, serviceType, computed services)

**Non-Goals:**
- Keyboard layout switching at runtime (Redox doesn't support this yet)
- Console font selection (no font infrastructure for fbcond)
- Audio mixer/volume control (audiod has no runtime API for this)
- Full ICU/glibc locale support (Redox is C-locale only in relibc — the module sets env vars for software that reads them)

## Decisions

**1. Audio module owns the audiod service.**
The `audio.nix` module defines a computed `services` option (same pattern as `graphics.nix` and `networking.nix`). When `audio.enable = true`, it emits an `audiod` service entry. `init-scripts.nix` merges `inputs.audio.services` into the service collection alongside graphics, networking, snix, and iroh services.

The `hardware.audioEnable` flag still controls PCI driver loading (ihdad/ac97d/sb16d). The new `audio.enable` controls the userspace daemon. Both must be true for working audio. The audio module reads `hardware.audioEnable` and warns (via assertion) if `audio.enable = true` but `hardware.audioEnable = false`.

**2. Locale module sets environment variables only.**
Redox's relibc is C-locale only — there are no locale data files or `setlocale()` behavior changes. The module sets `LANG`, `LC_ALL`, and per-category `LC_*` variables in the environment. This matches what ported software reads (Rust's `std::env::var("LANG")`, Python's `locale.getdefaultlocale()`). The module injects into `environment.variables` via a computed option pattern, or directly into generated-files.

**3. Console module controls initfs script generation.**
Console options (VT numbers, enable flags) are read by `init-scripts.nix` when generating the `20_graphics` initfs script. The module doesn't own services (fbcond/inputd are initfs-stage daemons, not rootfs services) — it provides configuration that `init-scripts.nix` uses to template the script.

**4. Graphical profile sets both flags.**
`graphical.nix` gains `/audio = { enable = true; };` alongside its existing `/graphics.enable = true` and `/hardware.audioEnable = true`. This preserves identical behavior for existing users.

## Risks / Trade-offs

**Risk: Module proliferation.** Three new modules (audio, locale, console) increases the count from 19 to 22. Each module is small (20-60 lines) and covers a distinct subsystem, so the cognitive load is low. The alternative — cramming these into existing modules — is what created the audio-in-graphics problem.

**Trade-off: Locale is environment-only.** Setting LANG without locale data files means programs can read the variable but `setlocale()` in relibc still returns "C". This is honest — the module documents what it does — but could confuse users expecting full locale support. The description makes clear this is for env var signaling.

**Risk: Console module has limited utility today.** fbcond has few knobs. The module is small and mostly provides the VT number and enable flag. It becomes more useful if Redox gains console font support or multiple virtual consoles.
