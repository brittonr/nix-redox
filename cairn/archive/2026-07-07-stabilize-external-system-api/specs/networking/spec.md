## ADDED Requirements

### Requirement: Redox network primitives [r[networking.redox-network-primitives]]

Redox MUST expose networking primitives suitable for OnixOS substrate lowering without forcing IPv4-only assumptions. At minimum, the primitive surface MUST be able to represent DNS nameservers, DNS search domains, hostnames, IPv4 literals, IPv6 literals, and static address declarations with prefix length.

Runtime support MAY initially be partial, but validation and builder-shell diagnostics MUST preserve declared values or fail clearly when a primitive is unsupported.

#### Scenario: DNS search domains validate [r[networking.redox-network-primitives.scenario.search-domains]]

- GIVEN a Redox network primitive plan sets DNS nameservers and search domains
- WHEN primitive validation runs
- THEN both fields MUST be accepted
- AND generated configuration MUST preserve ordering where resolver semantics depend on order

#### Scenario: IPv6 literal accepted [r[networking.redox-network-primitives.scenario.ipv6]]

- GIVEN a network primitive declares an IPv6 literal address for a supported field
- WHEN validation runs
- THEN the value MUST be accepted
- AND it MUST NOT be coerced into an IPv4-only format

#### Scenario: Unsupported runtime field fails clearly [r[networking.redox-network-primitives.scenario.unsupported]]

- GIVEN a network primitive declares a field that the current Redox runtime cannot render
- WHEN the builder shell validates the plan
- THEN evaluation MUST fail with a diagnostic naming the unsupported field
- AND it MUST NOT silently discard the field
