#!/usr/bin/env python3
"""
Patch cargo to pass env vars via --env-set CLI flag in addition to Command::env().

On Redox, environment variables set via Command::env() don't propagate through
exec() to the child process. This means rustc doesn't see env vars like OUT_DIR,
CARGO_PKG_*, and cargo:rustc-env values when processing env!() / option_env!()
macros at compile time.

Fix: For env vars that rustc reads via env!()/option_env!(), also pass them as
--env-set flags. The --env-set flag is a rustc nightly feature that populates the
logical_env map, which is checked BEFORE std::env::var() in the env!() expansion.

Patched files:
  src/tools/cargo/src/cargo/core/compiler/mod.rs
  src/tools/cargo/src/cargo/core/compiler/compilation.rs
"""

import sys
import os


def patch_mod_rs(root_dir):
    """Patch mod.rs: cargo:rustc-env values and OUT_DIR."""
    path = os.path.join(root_dir, "src/tools/cargo/src/cargo/core/compiler/mod.rs")
    if not os.path.exists(path):
        print(f"  File not found: {path}")
        return False

    with open(path, 'r') as f:
        content = f.read()

    original = content

    # Patch 1: cargo:rustc-env values in add_custom_flags
    old = '''                for (name, value) in output.env.iter() {
                    cmd.env(name, value);
                }'''
    new = '''                if !output.env.is_empty() {
                    // REDOX: Also pass via --env-set so rustc sees it in env!() macro.
                    // On Redox, Command::env() doesn't propagate through exec().
                    cmd.arg("-Z").arg("unstable-options");
                }
                for (name, value) in output.env.iter() {
                    cmd.env(name, value);
                    cmd.arg("--env-set").arg(format!("{}={}", name, value));
                }'''
    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: cargo:rustc-env → also --env-set")
    else:
        print(f"  WARNING: Could not find cargo:rustc-env pattern in mod.rs")

    # Patch 2: OUT_DIR
    old_out_dir = '''            cmd.env(
                "OUT_DIR",
                &build_runner.files().build_script_out_dir(&dep.unit),
            );'''
    new_out_dir = '''            let out_dir = build_runner.files().build_script_out_dir(&dep.unit);
            cmd.env("OUT_DIR", &out_dir);
            // REDOX: Also pass OUT_DIR via --env-set for env!() macro.
            cmd.arg("-Z").arg("unstable-options");
            cmd.arg("--env-set").arg(format!("OUT_DIR={}", out_dir.display()));'''
    if old_out_dir in content:
        content = content.replace(old_out_dir, new_out_dir)
        print(f"  Patched: OUT_DIR → also --env-set")
    else:
        print(f"  WARNING: Could not find OUT_DIR pattern in mod.rs")

    if content != original:
        with open(path, 'w') as f:
            f.write(content)
        return True
    return False


def patch_compilation_rs(root_dir):
    """Patch compilation.rs: CARGO_PKG_* and CARGO_MANIFEST_* env vars."""
    path = os.path.join(root_dir, "src/tools/cargo/src/cargo/core/compiler/compilation.rs")
    if not os.path.exists(path):
        print(f"  File not found: {path}")
        return False

    with open(path, 'r') as f:
        content = f.read()

    original = content

    # Patch: After CARGO_PKG_* env vars are set, add --env-set for each
    old_pkg = '''        cmd.env("CARGO_MANIFEST_DIR", pkg.root())
            .env("CARGO_MANIFEST_PATH", pkg.manifest_path())
            .env("CARGO_PKG_VERSION_MAJOR", &pkg.version().major.to_string())
            .env("CARGO_PKG_VERSION_MINOR", &pkg.version().minor.to_string())
            .env("CARGO_PKG_VERSION_PATCH", &pkg.version().patch.to_string())
            .env("CARGO_PKG_VERSION_PRE", pkg.version().pre.as_str())
            .env("CARGO_PKG_VERSION", &pkg.version().to_string())
            .env("CARGO_PKG_NAME", &*pkg.name());

        for (key, value) in pkg.manifest().metadata().env_vars() {
            cmd.env(key, value.as_ref());
        }'''

    new_pkg = '''        cmd.env("CARGO_MANIFEST_DIR", pkg.root())
            .env("CARGO_MANIFEST_PATH", pkg.manifest_path())
            .env("CARGO_PKG_VERSION_MAJOR", &pkg.version().major.to_string())
            .env("CARGO_PKG_VERSION_MINOR", &pkg.version().minor.to_string())
            .env("CARGO_PKG_VERSION_PATCH", &pkg.version().patch.to_string())
            .env("CARGO_PKG_VERSION_PRE", pkg.version().pre.as_str())
            .env("CARGO_PKG_VERSION", &pkg.version().to_string())
            .env("CARGO_PKG_NAME", &*pkg.name());

        // REDOX: Also pass CARGO_PKG_* via --env-set for env!() macro.
        // On Redox, Command::env() doesn't propagate through exec().
        cmd.arg("-Z").arg("unstable-options");
        cmd.arg("--env-set").arg(format!("CARGO_MANIFEST_DIR={}", pkg.root().display()));
        cmd.arg("--env-set").arg(format!("CARGO_MANIFEST_PATH={}", pkg.manifest_path().display()));
        cmd.arg("--env-set").arg(format!("CARGO_PKG_VERSION_MAJOR={}", pkg.version().major));
        cmd.arg("--env-set").arg(format!("CARGO_PKG_VERSION_MINOR={}", pkg.version().minor));
        cmd.arg("--env-set").arg(format!("CARGO_PKG_VERSION_PATCH={}", pkg.version().patch));
        cmd.arg("--env-set").arg(format!("CARGO_PKG_VERSION_PRE={}", pkg.version().pre.as_str()));
        cmd.arg("--env-set").arg(format!("CARGO_PKG_VERSION={}", pkg.version()));
        cmd.arg("--env-set").arg(format!("CARGO_PKG_NAME={}", pkg.name()));

        for (key, value) in pkg.manifest().metadata().env_vars() {
            cmd.env(key, value.as_ref());
            cmd.arg("--env-set").arg(format!("{}={}", key, value.as_ref()));
        }'''

    if old_pkg in content:
        content = content.replace(old_pkg, new_pkg)
        print(f"  Patched: CARGO_PKG_* → also --env-set")
    else:
        print(f"  WARNING: Could not find CARGO_PKG_* pattern in compilation.rs")

    if content != original:
        with open(path, 'w') as f:
            f.write(content)
        return True
    return False


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <rust-source-dir>")
        sys.exit(1)

    root_dir = sys.argv[1]
    ok = False

    print(f"Patching cargo compiler files for --env-set on Redox...")
    if patch_mod_rs(root_dir):
        ok = True
    if patch_compilation_rs(root_dir):
        ok = True

    if ok:
        print("Done! cargo will pass env vars via --env-set for Redox.")
    else:
        print("WARNING: No patches applied!")
        sys.exit(1)
