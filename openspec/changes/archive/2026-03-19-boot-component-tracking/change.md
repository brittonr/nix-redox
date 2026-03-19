# Archive: boot-component-tracking
**Date:** 2026-03-19
**Status:** Implemented

## Summary
Implemented tracking system for boot components to enable selective updates and rollbacks.
Detects changes in bootloader, kernel, and initfs to minimize unnecessary updates.

## Key Files
- snix-redox/src/activate.rs: boot_components_changed(), update_boot_components()
