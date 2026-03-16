# Influences


This page explains how Redox was influenced by other operating systems.

(The list is ordered by influence level)
## [Minix


The most influential Unix-like system with a microkernel. It has advanced features such as system modularity, [kernel panic resistence, driver reincarnation, protection against bad drivers and secure interfaces for [process comunication.

Redox is largely influenced by Minix - it has a similar architecture but with a feature set written in Rust.

- [How Minix influenced the Redox design
## [seL4


The most performant and simplest microkernel of the world.

Redox follow the same principle, trying to make the kernel-space small as possible (moving components to user-space and reducing the number of system calls, passing the complexity to user-space) and keeping the overall performance good (reducing the context switch cost).
## [Plan 9


This Bell Labs OS brings the concept of "Everything is a File" to the highest level, doing all the system communication from the filesystem.

- [Drew DeVault explains the Plan 9
- [Plan 9's influence on Redox
## [Linux


The most advanced monolithic kernel and biggest open-source project of the world. It brought several improvements and optimizations to the Unix-like world.

Redox tries to implement the Linux performance improvements in a microkernel design.
## [BSD


This Unix [family included several improvements on Unix systems and the open-source variants of BSD added many improvements to the original system (like Linux did).

-

[FreeBSD - The [Capsicum (a capability-based system) and [jails (a sandbox technology) influenced the Redox namespaces implementation.
-

[OpenBSD - The [system call, [filesystem, [display server and [audio server sandbox and [others influenced the Redox security.
