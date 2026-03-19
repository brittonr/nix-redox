# Archive: rebuild-auto-routing
**Date:** 2026-03-19
**Status:** Implemented

## Summary
Implemented automatic routing between local and bridge rebuild paths based on configuration changes.
Enables smart rebuild decisions: package changes use bridge when available, config-only changes stay local.

## Key Files
- snix-redox/src/rebuild.rs auto_rebuild() function
- needs_bridge() detection logic for routing decisions
