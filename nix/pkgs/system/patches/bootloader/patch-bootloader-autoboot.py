#!/usr/bin/env python3
"""Patch bootloader to auto-select best resolution when 'autoboot' feature is enabled.

When cfg!(feature = "autoboot") is true, select_mode() skips the interactive
mode selection menu and immediately returns the mode matching best_resolution().
This removes the need to manually press Enter at the resolution picker.

The 'live' feature is orthogonal — it controls whether the disk is loaded
into RAM. Both can be combined for fully unattended boot.
"""

import sys
import os


def patch_file(filepath, old, new):
    with open(filepath, "r") as f:
        content = f.read()
    if old not in content:
        print(f"WARNING: patch target not found in {filepath}")
        print(f"  Looking for: {repr(old[:80])}...")
        return False
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print(f"  Patched {filepath}")
    return True


def patch_main(src_dir):
    main_rs = os.path.join(src_dir, "src/main.rs")

    # After best_resolution is determined and `selected` is set,
    # add an early return when autoboot feature is enabled.
    # The target text is right after the best_resolution loop.
    patch_file(
        main_rs,
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

    # Add the feature to Cargo.toml
    cargo_toml = os.path.join(src_dir, "Cargo.toml")
    patch_file(
        cargo_toml,
        'serial_debug = []',
        'serial_debug = []\nautoboot = ["live"]',
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <bootloader-src-dir>")
        sys.exit(1)
    patch_main(sys.argv[1])
