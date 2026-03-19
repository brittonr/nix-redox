# Archive: parallel-build-fix
**Date:** 2026-03-19
**Status:** Implemented

## Summary
Fixed parallel build hangs through fork-lock patch and lld-wrapper stack overflow fixes.
Enables reliable multi-job cargo builds and parallel compilation on Redox.

## Key Files
- patches/patch-relibc-fork-lock.py
- lld-wrapper (16MB stack thread + exec)
