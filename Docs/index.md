# AgentLease documentation

* [Implementation brief](IMPLEMENTATION_BRIEF.md) - Defines the version-one ownership contract, safety invariants, tests, and implementation milestones.
* [Direct exec lifecycle](direct-exec.md) - Records direct replacement, descriptor handoff, signal-mask inheritance, and failure behavior.
* [Locking core](locking-core.md) - Records the filesystem and descriptor invariants implemented by the locking core.
* [Shared resources and inherited descriptor manifest](shared-resources.md) - Defines AgentLease 2 shared/exclusive acquisition, versioned records, and the trusted-child descriptor envelope.
* [Status inspection](status.md) - Records authoritative read-only probes, metadata classifications, and stable output behavior.
* [Supervised run lifecycle](supervised-run.md) - Records run-mode validation, publication, descriptor inheritance, signal teardown, and exit precedence.
* [Swift Subprocess integration](subprocess-integration.md) - Records the compiled process-lifecycle and descriptor-inheritance proofs behind supervised execution.
* [Verification map](verification.md) - Maps the original release scenarios and AgentLease 2 regressions to automated tests.
