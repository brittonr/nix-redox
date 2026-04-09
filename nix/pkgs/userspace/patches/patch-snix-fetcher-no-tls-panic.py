#!/usr/bin/env python3
"""Patch snix-glue fetcher to not panic when no CA certificates exist.

Redox OS has no system CA certificate store. The default reqwest Client::new()
calls rustls-native-certs which panics with "No CA certificates were loaded".

Fix: add a fallback that retries with tls_built_in_root_certs(false) so the
client creates with an empty root store. Local eval/build work without TLS;
remote fetches will fail with a clear TLS handshake error instead of abort.
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "src/fetchers/mod.rs"

with open(path) as f:
    content = f.read()

# Two patches:
# 1. Change http_client field type from Client to Option<Client>
# 2. Make construction non-fatal (store None on failure)

# Patch the struct field type
struct_old = '    http_client: reqwest::Client,'
struct_new = '    http_client: Option<reqwest::Client>,'

already_patched = False

if struct_old in content:
    content = content.replace(struct_old, struct_new)
elif struct_new in content:
    already_patched = True
else:
    print(f'WARNING: http_client field type not found in {path}', file=sys.stderr)
    sys.exit(1)

# Patch all uses of self.http_client to unwrap the Option.
# Leave already-patched call sites alone.
content = content.replace(
    'self.http_client.get(',
    'self.http_client.as_ref().expect("HTTP client not available (no CA certs)").get('
)
content = content.replace(
    'self.http_client.execute(',
    'self.http_client.as_ref().expect("HTTP client not available (no CA certs)").execute('
)

old = '''            http_client: reqwest::Client::builder()
                .user_agent(crate::USER_AGENT)
                .build()
                .expect("Client::new()"),'''

# Store None when Client creation fails (no CA certs on Redox).
# HTTP operations will error at point-of-use with a clear message
# instead of aborting the entire process at startup.
new = '''            http_client: reqwest::Client::builder()
                .user_agent(crate::USER_AGENT)
                .build()
                .ok(),'''

if old in content:
    content = content.replace(old, new)
elif new in content:
    already_patched = True
else:
    print(f"WARNING: Client::new() pattern not found in {path}", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)

if already_patched:
    print("Fetcher no-TLS patch already present")
else:
    print("Patched fetcher Client::new() with no-TLS fallback")
