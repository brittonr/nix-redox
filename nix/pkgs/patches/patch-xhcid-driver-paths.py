#!/usr/bin/env python3
"""Patch xhcid sub-driver path lookup to try multiple locations.

During initfs boot, drivers are at /bin/. After rootfs switchroot, they're
at /usr/lib/drivers/. This patch makes xhcid try the rootfs path first,
falling back to the initfs path.

Usage: python3 patch-xhcid-driver-paths.py <path-to-xhcid-mod.rs>
"""
import sys


def main():
    path = sys.argv[1]

    with open(path, "r") as f:
        content = f.read()

    old = """let command = if command.starts_with('/') {
                    command.to_owned()
                } else {
                    "/usr/lib/drivers/".to_owned() + command
                };"""

    new = """let command = if command.starts_with('/') {
                    command.to_owned()
                } else {
                    // Try multiple paths: rootfs first, then initfs fallback
                    let rootfs_path = "/usr/lib/drivers/".to_owned() + command;
                    let initfs_path = "/bin/".to_owned() + command;
                    if std::path::Path::new(&rootfs_path).exists() {
                        rootfs_path
                    } else {
                        initfs_path
                    }
                };"""

    if old not in content:
        print("WARNING: xhcid driver path pattern not found, skipping")
        return

    content = content.replace(old, new, 1)

    with open(path, "w") as f:
        f.write(content)

    print("xhcid sub-driver path lookup patched")


if __name__ == "__main__":
    main()
