## ADDED Requirements

### Requirement: Self-hosting proof runs create a standard capture directory

Focused and full self-hosting validation entry points SHALL create a timestamped capture directory with a standard file layout. Each capture directory SHALL contain at least `meta.txt`, raw run output, guest serial log, host monitor log when applicable, and any VMM or runner log required to audit the run end to end.

#### Scenario: Focused proof run creates standard capture
- **WHEN** a focused self-hosting proof wrapper starts
- **THEN** it creates a timestamped capture directory
- **AND** the directory contains metadata plus the required guest/host logs for that run

#### Scenario: Full proof run creates standard capture
- **WHEN** a full self-hosting proof wrapper starts
- **THEN** it creates the same standard capture layout
- **AND** the resulting directory is suitable for later audit without relying on pueue history

#### Scenario: Capture layout contains required files
- **WHEN** a proof run capture directory is inspected after the wrapper exits
- **THEN** `meta.txt` is present
- **AND** a machine-readable summary file is present
- **AND** a human-readable excerpt file is present
- **AND** the raw run output and guest serial log are present
- **AND** any host monitor or VMM log used by that flow is present when the wrapper collected it

### Requirement: Each proof run emits machine-readable summary and human excerpt

Every standardized proof run SHALL produce both a machine-readable summary and a short human-readable excerpt alongside the raw logs. The summary SHALL use the same field names for focused and full proof wrappers.

#### Scenario: Passing run emits summary outputs
- **WHEN** a proof run completes
- **THEN** the capture directory contains a summary JSON file with pass/fail metadata
- **AND** the summary JSON records at least the flow name, run identifier, start time, end time or duration, verdict, and capture directory path
- **AND** contains a short text excerpt suitable for evidence references

### Requirement: Latest successful proof runs are indexed

The repo SHALL maintain an index of the latest successful capture for each major self-hosting proof flow.

#### Scenario: Successful focused run refreshes index
- **WHEN** a focused proof flow completes successfully
- **THEN** the latest-success index points that flow at the new capture directory

#### Scenario: Failed run does not replace success index
- **WHEN** a proof flow fails
- **THEN** the failure capture is retained for debugging
- **AND** the latest-success index continues to reference the most recent successful capture

#### Scenario: Focused and full wrappers emit the same summary fields
- **WHEN** a focused proof run and a full proof run both produce summary JSON
- **THEN** both summaries use the same required field names for flow name, run identifier, timing, verdict, and capture directory path
