# AgentLease documentation

* [Implementation brief](IMPLEMENTATION_BRIEF.md) - Defines the version-one ownership contract, safety invariants, tests, and implementation milestones.
* [Direct exec lifecycle](direct-exec.md) - Records direct replacement, descriptor handoff, signal-mask inheritance, and failure behavior.
* [Locking core](locking-core.md) - Records the filesystem and descriptor invariants implemented by the locking core.
* [Status inspection](status.md) - Records authoritative read-only probes, metadata classifications, and stable output behavior.
* [Supervised run lifecycle](supervised-run.md) - Records run-mode validation, publication, descriptor inheritance, signal teardown, and exit precedence.
* [Swift Subprocess integration](subprocess-integration.md) - Records the compiled process-lifecycle and descriptor-inheritance proofs behind supervised execution.
* [Version 1 verification map](verification.md) - Maps all 29 required scenarios to their primary automated regression tests.
