#!/usr/bin/env python3
"""Patch bootloader to auto-select best resolution when 'autoboot' feature is enabled.

When cfg!(feature = "autoboot") is true, select_mode() skips the interactive
mode selection menu and immediately returns the mode matching best_resolution().
This removes the need to manually press Enter at the resolution picker.

The 'live' feature is orthogonal — it controls whether the disk is loaded
into RAM. Both can be combined for fully unattended boot.

Targets match bootloader revision 11b85164383c1dfc0415a36b389f6eb999b9b2f5.
Validate every target before writing either file: source drift must fail the
build, never leave a successfully or partially patched source tree.
"""

from pathlib import Path
import sys


def prepare_patch(filepath, old, new):
    content = filepath.read_text()
    occurrences = content.count(old)
    if occurrences != 1:
        raise ValueError(
            f"{filepath}: expected exactly one autoboot patch target, "
            f"found {occurrences}: {old!r}"
        )
    return filepath, content.replace(old, new, 1)


def patch_main(src_dir):
    src_dir = Path(src_dir)

    # Prepare both edits before touching the source tree. In particular, a
    # missing Cargo feature anchor must not leave main.rs modified.
    main_patch = prepare_patch(
        src_dir / "src/main.rs",
        '    println!();\n'
        '\n'
        '    println!("Arrow keys and enter select mode");',
        '    println!();\n'
        '\n'
        '    // autoboot: skip interactive menu, use best resolution\n'
        '    if cfg!(feature = "autoboot") {\n'
        '        if let Some(mode_i) = modes.iter().position(|x| x.0.id == selected) {\n'
        '            println!("autoboot: selecting {}",  modes[mode_i].1);\n'
        '            return Some(modes[mode_i].0);\n'
        '        }\n'
        '    }\n'
        '\n'
        '    println!("Arrow keys and enter select mode");',
    )

    cargo_patch = prepare_patch(
        src_dir / "Cargo.toml",
        'serial_debug = []',
        'serial_debug = []\nautoboot = []',
    )

    for filepath, content in (main_patch, cargo_patch):
        filepath.write_text(content)
        print(f"  Patched {filepath}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <bootloader-src-dir>")
        sys.exit(1)
    try:
        patch_main(sys.argv[1])
    except (OSError, ValueError) as error:
        print(f"autoboot patch failed: {error}", file=sys.stderr)
        sys.exit(1)
