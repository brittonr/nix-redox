# Schemes


The **scheme**, which takes its name from [URI schemes, identifies the type of resource, and identifies the manager daemon responsible for that resource.

Within Redox, a scheme may be thought of in a few ways. It is all of these things:

- The **type** of a resource, such as "file", "NVMe drive", "TCP connection", etc. (Note that these are not valid scheme names, they are just given by way of example.)
- The starting point for locating the resource, i.e. it is the root of the path to the resource, which the system can then use in establishing a connection to the resource.
- A **uniquely named service** that is provided by some driver or daemon program, with the full path identifying a specific resource accessed via that service.
## Scheme Daemons


A scheme is typically provided by a **daemon**. A daemon is a program that runs as a process in userspace; it is typically started by the system during boot. When the process starts, it registers with kernel using the name of the scheme that it manages.
## Kernel vs. Userspace Schemes


A userspace scheme is implemented by a scheme daemon, described above. A kernel scheme is implemented within the kernel, and manages critical resources not easily managed with a userspace daemon. When possible, schemes should be implemented in userspace.
## Accessing Resources


In order to provide "virtual file" behavior, schemes generally implement file-like operations. However, it is up to the scheme provider to determine what each file-like operation means. For example, `seek` to an SSD driver scheme might simply add to a file offset, but to a floppy disk controller scheme, it might cause the physical movement of disk read-write heads.

Typical scheme operations include:

- `open` - Create a **handle** (file descriptor) to a resource provided by the scheme. e.g. `File::create("/scheme/tcp/127.0.0.1/3000")` in a regular program would be converted by the kernel into `open("127.0.0.1/3000")` and sent to the "tcp" scheme provider. The "tcp" scheme provider would parse the name, establish a connection to Internet address "127.0.0.1", port "3000", and return a handle that represents that connection.
- `read` - get some data from the thing represented by the handle, normally consuming that data so the next `read` will return new data.
- `write` - send some data to the thing represented by the handle to be saved, sent or written.
- `seek` - change the logical location where the next `read` or `write` will occur. This may or may not cause some action by the scheme provider.

Schemes may choose to provide other standard operations, such as `mkdir`, but the meaning of the operation is up to the scheme. `mkdir` might create a directory entry, or it might create some type of substructure or container relevant to that particular scheme.

Some schemes implement `fmap`, which creates a memory-mapped area that is shared between the scheme resource and the scheme user. It allows direct memory operations on the resource, rather than reading and writing to a file descriptor. The most common use case for `fmap` is for a device driver to access the physical addresses of a memory-mapped device, using the `memory:` kernel scheme. It is also used for frame buffers in the graphics subsystem.
>

TODO: add F-operations.
>

TODO: explain file-like vs. socket-like schemes.
## Userspace Schemes


Redox creates user-space schemes during initialization, starting various daemon-style programs, each of which can provide one or more schemes. ************[[[[[[[[[[[[[[[[[
| Scheme                    | Daemon              | Description                                                   |
| ------------------------- | ------------------- | ------------------------------------------------------------- |
| disk.*                    | ided, ahcid, nvmed  | Storage drivers                                               |
| disk.live                 | lived               | RAM-disk driver that loads the bootable USB data into RAM     |
| disk.usb-{id}+{port}-scsi | usbscsid            | USB SCSI driver                                               |
| logging                   | ramfs               | Error logging scheme, using an in-memory temporary filesystem |
| initfs                    | bootstrap           | Startup filesystem                                            |
| file                      | redoxfs             | Main filesystem                                               |
| network                   | e1000d, rtl8168d    | Link-level network send/receive                               |
| ip                        | smolnetd            | Raw IP packet send/receive                                    |
| tcp                       | smolnetd            | TCP sockets                                                   |
| udp                       | smolnetd            | UDP sockets                                                   |
| icmp                      | smolnetd            | ICMP protocol                                                 |
| netcfg                    | smolnetd            | Network configuration                                         |
| display.vesa              | vesad               | VESA driver                                                   |
| display.virtio-gpu        | virtio-gpud         | VirtIO GPU driver                                             |
| orbital                   | orbital             | Windowing system (window manager and virtual driver)          |
| pty                       | ptyd                | Pseudoterminals, used by terminal emulators                   |
| audiorw                   | sb16d, ac97d, ihdad | Sound drivers                                                 |
| audio                     | audiod              | Audio manager and virtual device                              |
| usb.*                     | usb*d               | USB drivers                                                   |
| acpi                      | acpid               | ACPI driver                                                   |
| input                     | inputd              | Virtual device                                                |
| sudo                      | sudo                | Privilege manager                                             |
| chan                      | ipcd                | Inter-process communication                                   |
| shm                       | ipcd                | Shared memory manager                                         |
| log                       | logd                | Logging                                                       |
| rand                      | randd               | Pseudo-random number generator                                |
| zero                      | zerod               | Discard all writes, and always fill read buffers with zeroes  |
| null                      | nulld               | Discard all writes, and read no bytes                         |

## Kernel Schemes


The kernel provides a small number of schemes in order to support userspace. ************[[[``[[[[[[[[[[[
| Name        | Documentation | Description                                                                    |      |        |
| ----------- | ------------- | ------------------------------------------------------------------------------ | ---- | ------ |
| namespace   | root.rs       | Namespace manager                                                              |      |        |
| user        | user.rs       | Dispatch for user-space schemes                                                |      |        |
| debug       | debug.rs      | Debug messages that can't use the                                              | log: | scheme |
| event       | event.rs      | epoll-like file descriptor read/write "ready" events                           |      |        |
| irq         | irq.rs        | Interrupt manager (converts interrupts to messages)                            |      |        |
| pipe        | pipe.rs       | Kernel manager for pipes                                                       |      |        |
| proc        | proc.rs       | Process context manager                                                        |      |        |
| thisproc    | proc.rs       | Process context manager                                                        |      |        |
| sys         | mod.rs        | System hardware resources information                                          |      |        |
| kernel.acpi | acpi.rs       | Read the CPU configuration (number of cores, etc)                              |      |        |
| memory      | memory.rs     | Physical memory mapping manager                                                |      |        |
| time        | time.rs       | Real-time clock timer                                                          |      |        |
| itimer      | time.rs       | Interval timer                                                                 |      |        |
| serio       | serio.rs      | Serial I/O (PS/2) driver (must stay in the kernel due to PS/2 protocol issues) |      |        |

## Scheme List


This section has all Redox schemes in a list format to improve organization, coordination and focus.
### Userspace


- disk.*
- disk.live
- disk.usb-{id}+{port}-scsi
- logging
- initfs
- file
- network
- ip
- tcp
- udp
- icmp
- netcfg
- display.vesa
- display.virtio-gpu
- orbital
- pty
- audiorw
- audio
- usb.*
- sudo
- acpi
- input
- chan
- shm
- log
- rand
- zero
- null
### Kernel


- namespace
- user
- debug
- event
- irq
- pipe
- proc
- thisproc
- sys
- kernel.acpi
- memory
- time
- itimer
- serio
