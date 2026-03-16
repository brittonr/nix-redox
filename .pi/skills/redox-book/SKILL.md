---
description: Look up Redox OS documentation from the official book. Use when you need reference material on Redox OS concepts, schemes, kernel internals, boot process, drivers, porting, or build system.
---

# Redox OS Book Reference

Look up Redox OS documentation from the official book (https://doc.redox-os.org/book/).

## Local Cache

A full mirror of the book lives at `docs/redox-book/` in the repo root:

- **Index**: `docs/redox-book/INDEX.md` — table of contents with links to all pages
- **Pages**: `docs/redox-book/pages/<slug>.md` — individual chapter files (88 pages, ~700KB total)

## How to Use

### Quick lookup
Read the index to find the right page, then read the page:

```
read docs/redox-book/INDEX.md
read docs/redox-book/pages/schemes.md
```

### Search across the book
Use ripgrep to find content across all pages:

```
rg "pattern" docs/redox-book/pages/
```

### Key pages by topic

| Topic | Page |
|-------|------|
| Schemes & resources | `schemes.md`, `scheme-operation.md`, `scheme-rooted-paths.md`, `resources.md` |
| Boot process | `boot-process.md`, `build-phases.md` |
| Kernel internals | `kernel.md`, `memory.md`, `scheduling.md`, `communication.md` |
| Drivers | `drivers.md`, `user-space.md` |
| Filesystem | `redoxfs.md`, `everything-is-a-file.md` |
| Graphics/GUI | `graphics-windowing.md`, `gui.md` |
| Security | `security.md` |
| Porting apps | `porting-applications.md`, `porting-case-study.md` |
| Build system | `build-system-reference.md`, `configuration-settings.md`, `coding-and-building.md` |
| Libraries/APIs | `libraries-apis.md`, `components.md` |
| Shell (Ion) | `shell.md` |
| Developer FAQ | `developer-faq.md` |
| Debugging | `syscall-debug.md`, `troubleshooting.md` |

### Refresh the cache
To re-fetch the book (if upstream changed), run the refresh script:

```bash
bash docs/redox-book/refresh.sh
```

This fetches all 88 pages from doc.redox-os.org and converts them to markdown.

## Page Slug Reference

All pages in `docs/redox-book/pages/`:

```
introduction          introducing-redox     our-goals
philosophy            why-a-new-os          why-rust
redox-use-cases       how-redox-compares    influences
hardware-support      important-programs    side-projects
system-design         microkernels          boot-process
kernel                user-space            communication
memory                scheduling            drivers
redoxfs               graphics-windowing    security
features              package-management    schemes-resources
scheme-rooted-paths   resources             schemes
everything-is-a-file  stitching-it-all-together  scheme-operation
event-scheme          example               programs-libraries
components            gui                   shell
system-tools          getting-started       running-vm
real-hardware         installing            trying-out-redox
tasks                 pkg                   contributing
chat                  best-practices        literate-programming
writing-docs-correctly  style               rusting-properly
avoiding-panics       testing-practices     using-redox-gitlab
signing-in-to-gitlab  repository-structure  creating-proper-bug-reports
creating-proper-pull-requests  filing-issues  build-process
podman-build          building-redox        nothing-to-hello-world
configuration-settings  build-system-reference  advanced-podman-build
advanced-build        i686                  aarch64
raspi                 troubleshooting       build-phases
developing-for-redox  developer-faq         references
libraries-apis        coding-and-building   including-programs
porting-applications  porting-case-study    ci
performance           syscall-debug         quick-workflow
asking-questions
```
