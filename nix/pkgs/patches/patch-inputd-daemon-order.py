#!/usr/bin/env python3
"""Patch inputd main.rs to move setup_logging() inside the daemon callback.

Without this, inputd calls setup_logging() before SchemeDaemon::new(), which
can interfere with the INIT_NOTIFY fd or cause blocking I/O through the
namespace manager. All other scheme daemons (fbcond, fbbootlogd, etc.) call
setup_logging() inside their daemon callback.

Usage: python3 patch-inputd-daemon-order.py <path-to-inputd-main.rs>
"""
import sys


def main():
    path = sys.argv[1]

    with open(path, "r") as f:
        content = f.read()

    # The current pattern in inputd main():
    old = """    } else {
        common::setup_logging(
            "input",
            "inputd",
            "inputd",
            common::output_level(),
            common::file_level(),
        );

        daemon::SchemeDaemon::new(daemon_runner);
    }"""

    new = """    } else {
        daemon::SchemeDaemon::new(daemon_runner);
    }"""

    if old not in content:
        print("WARNING: inputd main() pattern not found, skipping")
        return

    content = content.replace(old, new, 1)

    # Now add setup_logging to the beginning of the deamon() function
    old_deamon = """fn deamon(daemon: daemon::SchemeDaemon) -> anyhow::Result<()> {
    // Create the ":input" scheme.
    let socket_file = Socket::create()?;"""

    new_deamon = """fn deamon(daemon: daemon::SchemeDaemon) -> anyhow::Result<()> {
    common::setup_logging(
        "input",
        "inputd",
        "inputd",
        common::output_level(),
        common::file_level(),
    );

    // Create the ":input" scheme.
    let socket_file = Socket::create()?;"""

    if old_deamon not in content:
        print("WARNING: deamon() function pattern not found, skipping")
        return

    content = content.replace(old_deamon, new_deamon, 1)

    with open(path, "w") as f:
        f.write(content)

    print("inputd daemon order patch applied")


if __name__ == "__main__":
    main()
