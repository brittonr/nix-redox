## ADDED Requirements

### Requirement: readme-covers-snix
README must describe snix: what it is (Nix evaluator + builder for Redox),
what it can do (eval, build, install, store/profile management, system
generations, flake installables), and how to use it.

#### Scenario: reader wants to understand snix
- **WHEN** reading the README
- **THEN** there is a section explaining snix with example commands (`snix build .#ripgrep`, `snix install`, `snix system rebuild`)

### Requirement: readme-covers-scheme-daemons
README must describe the stored and profiled scheme daemons and their role
in the Nix store architecture on Redox.

#### Scenario: reader wants to understand scheme integration
- **WHEN** reading the README
- **THEN** there is a brief explanation of how stored/profiled map Nix store paths into Redox's namespace system

### Requirement: readme-covers-self-hosting
README must describe the self-hosting capability: cargo, rustc, and proc-macros
running on Redox, with current test counts.

#### Scenario: reader wants to know self-hosting status
- **WHEN** reading the README
- **THEN** there is a section covering what works (cargo build, proc-macros, build scripts, snix self-compile) and known limits (JOBS=1, intermittent hangs)

### Requirement: readme-covers-build-bridge
README must describe the build bridge (virtio-fs live package delivery from
host to guest).

#### Scenario: reader wants to iterate without rebuilding images
- **WHEN** reading the README
- **THEN** there are commands for `run-redox-shared`, `push-to-redox`, and `build-bridge`

### Requirement: readme-covers-network-cache
README must describe remote binary cache installation via HTTP.

#### Scenario: reader wants to install packages from a server
- **WHEN** reading the README
- **THEN** there is an example of `snix install --cache-url http://...`

### Requirement: readme-accurate-test-counts
README test section must reflect current counts.

#### Scenario: reader checks test coverage
- **WHEN** reading the Testing section
- **THEN** counts match reality: 461+ host unit tests, 129+ functional VM tests, 58+ self-hosting tests
