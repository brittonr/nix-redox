## ADDED Requirements

### Requirement: Options JSON generation
The flake SHALL expose a `packages.optionsJSON` derivation that contains a JSON file describing all adios module options — name, type, default, and description — extracted from the module tree.

#### Scenario: Options JSON is buildable
- **WHEN** a user runs `nix build .#optionsJSON`
- **THEN** the output contains `options.json` with an entry for every module option

#### Scenario: Options JSON contains expected fields
- **WHEN** `options.json` is read
- **THEN** each entry has `path` (e.g. "/boot.diskSizeMB"), `type`, `default` (if present), and `description`

### Requirement: Options Markdown generation
The flake SHALL expose a `packages.optionsMarkdown` derivation that renders the options JSON into a human-readable Markdown reference document.

#### Scenario: Options Markdown is buildable
- **WHEN** a user runs `nix build .#optionsMarkdown`
- **THEN** the output contains `options.md` with a section per module and a row per option

#### Scenario: Markdown includes all modules
- **WHEN** `options.md` is read
- **THEN** it contains sections for every module in the redox-system tree (boot, hardware, networking, environment, filesystem, graphics, services, users, etc.)
