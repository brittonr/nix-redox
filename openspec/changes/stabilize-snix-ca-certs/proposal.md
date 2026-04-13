## Why

Remote fetch and channel flows in snix still have a weak trust story on Redox because CA certificate discovery is inconsistent. Some paths rely on ad hoc `SSL_CERT_FILE` setup, some panic when no CA bundle exists, and self-built binaries can behave differently from the packaged binary. That makes remote cache and update work feel less real than the local self-hosting path.

## What Changes

- Add one deterministic CA bundle discovery path for snix and the upstream clients it wraps.
- Make TLS-dependent commands fail clearly and non-panically when no CA bundle exists, while preserving local-only functionality.
- Ensure packaged snix and self-built snix use the same CA discovery and error behavior.
- Add focused HTTPS validation so regressions show up before larger remote-cache or channel work.

## Capabilities

### New Capabilities
- `tls-ca-bundle-discovery`: Discover trust roots predictably for snix HTTP clients and degrade safely when the guest has no CA bundle.

### Modified Capabilities

None.

## Impact

- **snix**: startup bootstrap, HTTP client construction, fetchers, cache access, channels, and source-bundle behavior.
- **Validation**: HTTPS-focused tests for packaged and self-built binaries.
- **Docs**: Redox CA expectations, supported bundle paths, and failure modes.
- **Future work**: remote cache and channel features get a cleaner foundation.
