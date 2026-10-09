# AgentLease documentation

* [Implementation brief](IMPLEMENTATION_BRIEF.md) - Defines the ownership contract, version amendments, safety invariants, tests, and implementation milestones.
* [Direct exec lifecycle](direct-exec.md) - Records direct replacement, descriptor handoff, signal-mask inheritance, and failure behavior.
* [Locking core](locking-core.md) - Records filesystem, descriptor, registry coordination, and persistence invariants.
* [Coordinated retention](retention.md) - Defines guarded idle-resource retirement, conservative run-history pruning, and opt-in daily cleanup.
* [Shared resources and inherited descriptor manifest](shared-resources.md) - Defines AgentLease 2 shared/exclusive acquisition, versioned records, and the trusted-child descriptor envelope.
* [Status inspection](status.md) - Records authoritative read-only probes, metadata classifications, and stable output behavior.
* [Supervised run lifecycle](supervised-run.md) - Records run-mode validation, publication, descriptor inheritance, signal teardown, and exit precedence.
* [Swift Subprocess integration](subprocess-integration.md) - Records the compiled process-lifecycle and descriptor-inheritance proofs behind supervised execution.
* [Verification map](verification.md) - Maps original release scenarios, shared leases, and coordinated retention to automated regression coverage.
