# Archive: remote-binary-cache
**Date:** 2026-03-19
**Status:** Implemented

## Summary
Implemented remote binary cache support with HTTP fetching, NAR decompression, and recursive dependencies.
Enables network-based package installation with --cache-url CLI option and automatic fallback chains.

## Key Files
- snix-redox/src/cache.rs (fetch, fetch_recursive, path_info)
- snix-redox/src/cache_source.rs (CacheSource::Local/Remote)
- CLI --cache-url support on install/search/show commands
