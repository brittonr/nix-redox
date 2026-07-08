## ADDED Requirements

### Requirement: Redox service primitives [r[services.redox-service-primitives]]

Redox MUST expose a native service primitive suitable for OnixOS substrate lowering. The primitive MUST support service identity, command identity, argv-preserving arguments, service type/init phase, enablement, dependency ordering, and environment variables.

Existing Redox profiles that use legacy string `args` MUST remain valid internally, but the substrate primitive MUST provide structured argv so external consumers do not need to hand-quote shell strings.

#### Scenario: Structured argv renders deterministically [r[services.redox-service-primitives.scenario.argv]]

- GIVEN a service primitive declares `command = "/bin/exampled"` and `argv = [ "--flag" "value with spaces" ]`
- WHEN Redox validates and renders the primitive
- THEN the generated invocation MUST preserve the two argument boundaries
- AND the argument containing spaces MUST not be split accidentally

#### Scenario: Legacy profile args remain valid [r[services.redox-service-primitives.scenario.legacy]]

- GIVEN an existing Redox profile declares a service with legacy `args = "-D"`
- WHEN native Redox profile builds run
- THEN the service MUST remain valid
- AND rendering MUST preserve existing invocation semantics

#### Scenario: Malformed structured argv rejected [r[services.redox-service-primitives.scenario.reject]]

- GIVEN a service primitive declares structured arguments that are not a list of strings
- WHEN service primitive validation runs
- THEN validation MUST fail before image building
- AND the diagnostic MUST name the service and argv field
