# RedoxOS Module System Test Suite

Comprehensive tests for the adios-based module system at `nix/redox-system/`.

## Architecture

The test suite is organized in 4 layers, each testing a different aspect of the module system:

### Layer 1: Evaluation Tests (`eval.nix`)

**Purpose:** Verify the module system evaluates correctly without building cross-compiled packages.

**Method:** Uses mock packages (lightweight stand-ins) to test module evaluation in seconds instead of minutes.

**Tests:**
- `eval-profile-default` — Development profile evaluates
- `eval-profile-minimal` — Minimal profile evaluates
- `eval-profile-graphical` — Graphical profile evaluates
- `eval-profile-cloud` — Cloud Hypervisor profile evaluates
- `eval-extend-works` — `.extend` produces new system with merged options
- `eval-custom-users` — Custom user configuration works
- `eval-network-static` — Static network configuration
- `eval-network-disabled` — Disabled networking
- `eval-hardware-custom` — Custom hardware drivers
- `eval-environment-empty` — Empty system packages
- `eval-multi-module-merge` — Multiple module overrides merge correctly

**Run all:**
```bash
nix build .#checks.x86_64-linux.eval-profile-default
nix build .#checks.x86_64-linux.eval-extend-works
```

### Layer 2: Type Validation Tests (`types.nix`)

**Purpose:** Verify the Korora type system correctly validates inputs.

**Method:** Uses `builtins.tryEval` to verify invalid inputs fail and valid inputs pass.

**Tests:**
- `type-invalid-network-mode` — Rejects invalid network mode enum value
- `type-valid-network-mode-*` — Accepts all valid network modes (auto, dhcp, static, none)
- `type-invalid-storage-driver` — Rejects invalid storage driver
- `type-valid-storage-drivers` — Accepts all valid storage drivers
- `type-invalid-network-driver` — Rejects invalid network driver
- `type-invalid-graphics-driver` — Rejects invalid graphics driver
- `type-invalid-audio-driver` — Rejects invalid audio driver
- `type-invalid-user-missing-*` — Rejects users missing required fields (uid, gid, home, shell)
- `type-valid-user-complete` — Accepts user with all fields
- `type-valid-user-minimal` — Accepts user with only required fields
- `type-invalid-interface-missing-*` — Rejects interfaces missing required fields
- `type-invalid-bool-type` — Rejects wrong type for boolean field
- `type-invalid-int-type` — Rejects wrong type for int field
- `type-invalid-list-type` — Rejects wrong type for list field

**Run all:**
```bash
nix build .#checks.x86_64-linux.type-invalid-network-mode
nix build .#checks.x86_64-linux.type-valid-user-complete
```

### Layer 3: Build Artifact Tests (`artifacts.nix`)

**Purpose:** Verify built outputs contain expected files and content.

**Method:** Builds real derivations with mock packages, then inspects file content.

**Tests:**
- `artifact-rootTree-has-passwd` — /etc/passwd with semicolon format
- `artifact-rootTree-has-group` — /etc/group with semicolon format
- `artifact-rootTree-has-profile` — /etc/profile with environment variables
- `artifact-rootTree-has-init-scripts` — /etc/init.d/ scripts when networking enabled
- `artifact-rootTree-no-net-when-disabled` — No networking scripts when disabled
- `artifact-rootTree-has-static-netcfg` — Static network configuration script
- `artifact-rootTree-has-binaries` — Binaries from packages in /bin and /usr/bin
- `artifact-rootTree-has-home-dirs` — Home directories for users with createHome=true
- `artifact-rootTree-has-startup` — startup.sh script
- `artifact-rootTree-has-graphical-init` — Graphical init scripts when graphics enabled
- `artifact-drivers-all-types` — System builds with all driver types
- `artifact-rootTree-has-dns-config` — DNS configuration
- `artifact-rootTree-has-shell-aliases` — Custom shell aliases in profile
- `artifact-rootTree-has-shadow` — /etc/shadow with user entries
- `artifact-rootTree-multi-interface` — Multiple network interfaces

**Run all:**
```bash
nix build .#checks.x86_64-linux.artifact-rootTree-has-passwd
nix build .#checks.x86_64-linux.artifact-rootTree-has-binaries
```

### Layer 4: Library Function Tests (`lib.nix`)

**Purpose:** Verify helper functions in `nix/redox-system/lib.nix`.

**Method:** Direct unit tests of library functions.

**Tests:**
- `lib-passwd-format-basic` — Semicolon-delimited passwd format
- `lib-passwd-format-realname` — Custom realname field
- `lib-passwd-format-default-realname` — Realname defaults to username
- `lib-passwd-field-order` — Fields in correct order
- `lib-passwd-uses-semicolons` — Uses semicolons not colons (Redox vs Unix)
- `lib-group-format-basic` — Basic group format
- `lib-group-format-members` — Group with multiple members
- `lib-group-format-single-member` — Group with single member
- `lib-group-uses-semicolons` — Uses semicolons not colons
- `lib-group-members-comma-separated` — Members are comma-separated
- `lib-initrc-notify` — Init rc notify command format
- `lib-initrc-nowait` — Init rc nowait command format
- `lib-initrc-run` — Init rc run command format
- `lib-initrc-export` — Init rc export command format
- `lib-initrc-raw` — Init rc raw lines (comments)
- `lib-initrc-multiple` — Multiple init rc lines
- `lib-passwd-all-fields` — All passwd fields in correct positions
- `lib-group-all-fields` — All group fields in correct positions

**Run all:**
```bash
nix build .#checks.x86_64-linux.lib-passwd-format-basic
nix build .#checks.x86_64-linux.lib-group-format-members
```

## Running Tests

### Run All Tests
```bash
nix flake check
```

### Run Specific Test Layer
```bash
# Evaluation tests (fast)
nix build .#checks.x86_64-linux.eval-profile-default
nix build .#checks.x86_64-linux.eval-profile-minimal

# Type validation tests (fast)
nix build .#checks.x86_64-linux.type-invalid-network-mode
nix build .#checks.x86_64-linux.type-valid-user-complete

# Artifact tests (builds derivations)
nix build .#checks.x86_64-linux.artifact-rootTree-has-passwd
nix build .#checks.x86_64-linux.artifact-rootTree-has-binaries

# Library tests (fast)
nix build .#checks.x86_64-linux.lib-passwd-format-basic
nix build .#checks.x86_64-linux.lib-group-format-members
```

### List All Available Tests
```bash
nix eval .#checks.x86_64-linux --apply builtins.attrNames
```

### Filter Tests by Prefix
```bash
# All evaluation tests
nix eval .#checks.x86_64-linux --apply 'checks: builtins.filter (n: lib.hasPrefix "eval-" n) (builtins.attrNames checks)'

# All type tests
nix eval .#checks.x86_64-linux --apply 'checks: builtins.filter (n: lib.hasPrefix "type-" n) (builtins.attrNames checks)'
```

## Test Design Principles

### Mock Packages (`mock-pkgs.nix`)

Mock packages are lightweight stand-ins for real cross-compiled binaries:
- Create realistic directory structures (`/bin`, `/boot`, etc.)
- Use `pkgs.runCommand` for fast builds (seconds)
- Match the interface the build module expects

Example:
```nix
ion = mkMockPackageWithBins {
  name = "ion";
  binaries = ["ion" "sh"];
};
```

### Evaluation Tests

Use `nix-instantiate --eval --strict` to evaluate expressions without building:
```nix
system = redoxSystemFactory.redoxSystem {
  modules = [ ./profiles/development.nix ];
  pkgs = mockPkgs.all;
  hostPkgs = pkgs;
};

# Force evaluation of diskImage without building it
result = builtins.seq system.diskImage.outPath "SUCCESS";
```

### Type Validation Tests

Use `builtins.tryEval` to verify failures:
```nix
# This should FAIL because "bogus" is not in the NetworkMode enum
modules = [{
  "/networking" = { mode = "bogus"; };
}];
```

### Artifact Tests

Build with mock packages and inspect outputs:
```bash
if [ -e "$system_derivation/etc/passwd" ]; then
  if grep -qF 'root;0;0;root;/root;/bin/ion' "$system_derivation/etc/passwd"; then
    echo "✓ Passwd format correct"
  fi
fi
```

## Adding New Tests

### 1. Evaluation Test
Add to `eval.nix`:
```nix
my-new-test = mkEvalTest {
  name = "my-new-test";
  description = "Verifies XYZ works";
  modules = [ { "/path" = { option = value; }; } ];
};
```

### 2. Type Validation Test
Add to `types.nix`:
```nix
invalid-xyz = mkTypeFailTest {
  name = "invalid-xyz";
  description = "Verifies invalid XYZ is rejected";
  modules = [ { "/path" = { option = "invalid-value"; }; } ];
};
```

### 3. Artifact Test
Add to `artifacts.nix`:
```nix
rootTree-has-xyz = mkArtifactTest {
  name = "rootTree-has-xyz";
  description = "Verifies rootTree contains XYZ";
  modules = [ ... ];
  checks = [
    { file = "path/to/file"; contains = "expected-content"; }
  ];
};
```

### 4. Library Test
Add to `lib.nix`:
```nix
lib-xyz-format = mkLibTest {
  name = "xyz-format";
  description = "Verifies mkXYZ produces correct format";
  expression = "redoxLib.mkXYZ { ... }";
  expected = "expected-output";
};
```

## Test Output

Each test produces detailed output:
```
===============================================
RedoxOS Module System Evaluation Test: profile-default
===============================================

Description: Verifies default profile evaluates and produces disk image, initfs, and toplevel

Running evaluation...
✓ Evaluation succeeded

System outputs:
{ diskImage = "/nix/store/...-redox-disk-image"; initfs = "..."; toplevel = "..."; }

Test PASSED: profile-default
```

## Debugging Test Failures

### View test derivation
```bash
nix show-derivation .#checks.x86_64-linux.eval-profile-default
```

### Build test manually to see full output
```bash
nix build .#checks.x86_64-linux.eval-profile-default --show-trace -L
```

### Inspect test script
```bash
nix eval .#checks.x86_64-linux.eval-profile-default.drvPath
nix derivation show <path> | jq -r '.[].env.builder'
```

## Performance

- **Evaluation tests:** ~1-5 seconds each (uses mock packages)
- **Type tests:** ~1-3 seconds each (evaluation only)
- **Artifact tests:** ~10-30 seconds each (builds derivations with mock packages)
- **Library tests:** ~1-2 seconds each (direct function calls)

Total test suite runtime: ~5-10 minutes (vs hours for full cross-compilation)

## CI Integration

Tests are automatically run by `nix flake check`:
```yaml
# .github/workflows/ci.yml
- name: Run tests
  run: nix flake check --print-build-logs
```

## Coverage

Current test coverage:
- **Module evaluation:** 11 tests (profiles, extend, overrides)
- **Type validation:** 24 tests (enums, structs, type coercion)
- **Build artifacts:** 15 tests (files, content, format)
- **Library functions:** 18 tests (passwd, group, init.rc)

**Total:** 68 tests covering all module system components.
