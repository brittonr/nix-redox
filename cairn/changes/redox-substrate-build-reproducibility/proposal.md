# Proposal: Redox substrate build reproducibility

## Summary

Make the Redox substrate VM build used by OnixOS reproducible from checked-in Redox surfaces instead of proof-only temporary files.

## Motivation

The real OnixOS Redox VM proof succeeded, but it required a temporary `initfs-tools` hash repair and an ad-hoc CA-bundle environment override for fixed-output crate fetches. That is enough for exploratory evidence, not enough for repeatable Redox substrate support. External consumers need a repo-owned build path that either builds deterministically or fails with actionable diagnostics.

## Scope

- Refresh stale fixed-output hashes for Redox substrate infrastructure inputs used by the VM proof.
- Make certificate handling explicit for crate and vendor fixed-output fetches so proof commands do not depend on an operator-supplied `NIX_SSL_CERT_FILE`.
- Add a repo-owned Redox substrate VM proof fixture or manual gated check that builds the same artifact families used by OnixOS: kernel, initfs, RedoxFS, disk image, and QEMU runner.
- Document the exact manual check, expected outputs, and failure diagnostics.

## Affected specs

- `system-builder`: reproducible builder shell and VM artifact outputs.
- `substrate-ingredients`: public manifest/provenance for required ingredients.
- `testing`: repo-owned positive and negative reproducibility checks.
- `documentation`: operator runbook for the reproducible proof path.

## Non-goals

- Do not add an OnixOS dependency to Redox.
- Do not make real QEMU boot a mandatory default check if it is too heavy for normal CI.
- Do not claim Redox deploy, activation, physical install, rollback, or power-loss support.
- Do not replace the existing native Redox development profile workflow.

## Verification expectations

The change is complete when the real VM artifact build no longer needs temporary package files or ad-hoc certificate environment variables, the public substrate path can produce kernel/initfs/RedoxFS/disk/QEMU outputs from checked-in code, and focused positive/negative checks prove reproducible build behavior and fail-closed diagnostics.
