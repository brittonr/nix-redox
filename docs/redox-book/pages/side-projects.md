# Side Projects


Redox is a complete Rust operating system. In addition to the Redox kernel, our team is developing several side projects, including:

- [RedoxFS - Redox file system inspired by ZFS.
- [Ion - The Redox shell.
- [Orbital - The desktop environment/display server of Redox.
- [Orbclient - Orbital client library for Rust programs.
- [pkgutils - Redox package manager, with a command-line frontend and library.
- [relibc - Redox C library.
- [audiod - Redox audio server.
- [bootloader - Redox boot loader.
- [base - Redox essential system services and drivers.
- [installer - Redox buildsystem builder.
- [redoxer - A tool to run/test Rust programs inside of a Redox VM.
- [games - A collection of mini-games for Redox (alike BSD-games).
- and a few other exciting projects you can explore on the [redox-os group.

We also have some in-house tools, which are collections of small, useful command-line programs:

- [coreutils - Redox-specific core utilities such as `free`, `ps`, `shutdown`, and so on.
- [extrautils - Redox-specific extra utilities such as `dmesg`, `less`, `which`, and so on.
- [binutils - Utilities for working with binary files.

We also actively contribute to third-party projects that are heavily used in Redox.

- [uutils/coreutils - Cross-platform Rust rewrite of the GNU Coreutils.
- [smoltcp - The TCP/IP stack used by Redox.
- [winit - The window handling library for Rust programs.
## What tools are fitting for the Redox distribution?


The necessary tools for a usable system, we offer variants with fewer programs.

The listed tools fall into three categories:

- **Critical**, which are needed for a full functioning and usable system.
- **Ecosystem-friendly**, which are there for establishing consistency within the ecosystem.
- **Fun**, which are "nice" to have and are inherently simple.

The first category should be obvious: an OS without certain core tools is a useless OS. The second category contains the tools which are likely to be non-default in the future, but nonetheless are in the official distribution right now, for the charm. The third category is there for convenience: namely for making sure that the Redox infrastructure is consistent and integrated.
