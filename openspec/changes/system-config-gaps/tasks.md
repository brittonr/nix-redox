## Tasks

### 1. Add RTL8168 PCI entries to pcid.nix
- [ ] Add `rtl8168d` entry with vendor 0x10EC, devices 0x8168 and 0x8136, class 0x02
- [ ] Add comment for sb16d explaining ISA-only limitation
- [ ] Artifact test: rootTree with rtl8168d has pcid.d TOML with 0x10EC

### 2. Generate /etc/motd by default
- [ ] Add default motd to generated-files.nix ("Welcome to Redox OS!")
- [ ] Ensure user-provided `environment.etc."etc/motd"` overrides the default
- [ ] Artifact test: default rootTree has /etc/motd with welcome message

### 3. Generate /etc/shells
- [ ] Add /etc/shells to generated-files.nix listing /bin/ion and /bin/sh
- [ ] Artifact test: rootTree has /etc/shells with /bin/ion

### 4. Add contain and pkgutils to development profile
- [ ] Add `opt "contain"` and `opt "pkgutils"` to development.nix
- [ ] Eval test: development profile evaluates with these packages

### 5. Eval test for all declared drivers
- [ ] Add eval test that creates a system with all hardware driver enums populated
- [ ] Verify it evaluates without error
