## 1. Standardize the capture contract

- [ ] 1.1 Define the required files and directory layout for self-hosting proof captures.
- [ ] 1.2 Document which validation entry points must produce that layout automatically.
- [ ] 1.3 Add shared helper code or scripts for capture directory creation.

## 2. Emit summaries and excerpts

- [ ] 2.1 Generate a machine-readable summary JSON for each proof run.
- [ ] 2.2 Generate a short human-readable excerpt alongside the raw logs.
- [ ] 2.3 Ensure both focused and full validation wrappers produce the same summary fields.

## 3. Track latest successful proof runs

- [ ] 3.1 Add an index that records the latest successful capture for each major validation flow.
- [ ] 3.2 Update wrappers or post-processing so successful runs refresh the index automatically.
- [ ] 3.3 Update roadmap/docs to reference the indexed capture paths instead of freehand notes.

## 4. Validate the artifact flow end to end

- [ ] 4.1 Run at least one focused proof flow and one full proof flow through the new capture contract.
- [ ] 4.2 Verify the resulting directories contain the required logs, metadata, summary JSON, and excerpt text.
- [ ] 4.3 Attach example passing artifacts to the change evidence.
