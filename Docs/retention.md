---
type: Architecture
title: Coordinated retention
description: Defines guarded idle-resource retirement, conservative run-history pruning, and opt-in daily cleanup.
tags: [agentlease, flock, retention, coordination]
---

# Permanent coordination

AgentLease 2.1 uses one permanent `.registry.lock` in each state root. It is a
regular, singly linked, effective-user-owned file with mode `0600`, and is never
unlinked or replaced. Each registry claim opens a separate file description and
closes it to release ownership. Its descriptor stays close-on-exec and is absent
from `AGENTLEASE_LEASE_DESCRIPTORS`; resource and run/status schemas are unchanged.

Shared registry claims protect these operations:

- `FileLock`: from before resource opening through successful acquisition or
  descriptor closure, including every preopened waiter.
- `run` and `exec`: from before publishing `acquiring` through complete
  acquisition or acquisition-failure publication.
- Atomic JSON replacement: the complete temporary-write and rename operation.
- `status`: enumeration, metadata reads, and kernel probes.
- Inherited exclusive verification: inode validation through establishing the
  flock on the inherited description.

Cleanup attempts an exclusive registry claim nonblocking. A busy registry
produces a skipped report. Held resource leases release their acquisition claims,
so cleanup can inspect other idle files while applications remain open. Their
resource flocks continue protecting their inodes.

`run`, `exec`, and `LeaseSet` obtain shared admission with cancellation-aware
nonblocking polling, at most every 25 ms. Registry admission and resource
acquisition share `--wait-seconds`; expiry reports acquisition timeout. A signal
while `run` awaits admission cancels that wait before any record or child is
published. Synchronous inspection, publication, inherited verification, and
direct `FileLock` admission wait at most one second before reporting a state-I/O
failure.

# Retention policy

The default age is seven days. For an old resource lock, cleanup opens without
creating or following links, validates the safe file, obtains an independent
`LOCK_EX | LOCK_NB`, then repeats descriptor/path identity validation immediately
before unlinking. File modification time is an eligibility hint; kernel locking
establishes whether removal is safe. Shared ownership blocks this exclusive
probe just as exclusive ownership does. Timeout, cancellation, and acquisition
errors close pending claims together with their resource descriptors.

Run records are inspected before resource files are retired. A record must have
a managed UUID filename matching its run ID, supported schema 1 or 2, positive
process identifiers, a nonempty valid resource set, matching resource envelope,
and parseable timestamps. Reads are bounded to 1 MiB. Recent file modification
or recent `finishedAt` preserves a record; unfinished records use `startedAt`.
Live acquiring coordinator identities provide an additional conservative
preservation check, never ownership authority.

An old valid record is eligible only when every referenced resource is
kernel-free or safely absent under the exclusive registry claim. Any held,
unsafe, or indeterminate resource preserves it, regardless of current owner or
lease mode. This protects records for direct replacements, surviving children,
and descendants after coordinator exit. A historical record may remain longer
than seven days while another run uses the same resource. Malformed, oversized,
unrecognized, and unsafe entries remain untouched and appear as errors.

Explicit protections preserve selected lock inodes or diagnostic run records.
They are useful for idle descriptor handoffs and saved evidence that still
refers to a persistent path. A protected lock does not automatically preserve
its historical JSON; preserve the run UUID separately when needed.

# Commands and automatic cleanup

```sh
agentlease cleanup --json
agentlease cleanup --execute --json
agentlease cleanup --execute --older-than-days 14 --keep-run-id <uuid>
```

Without `--execute`, cleanup reports `wouldRemove` entries. `--execute` performs
the same guarded checks and reports removals. `--keep-lock-digest`,
`--keep-lock-path`, and `--keep-run-id` are repeatable, with at most 1,024 total
protections. Digests are lowercase 64-character SHA-256 values; paths must be
exact canonical resource-lock paths within the selected state root. Ages must
be finite and nonnegative. Cleanup JSON has independent schema version 1, with
busy state, per-entry actions/reasons, counts, and errors. Explicit cleanup
returns 70 for errors; a busy skip is successful. `status` remains read-only.

Automatic cleanup is disabled by default. `AGENTLEASE_AUTO_CLEANUP=1` enables a
best-effort pass before `run` or `exec` acquisition. It takes the same exclusive
registry claim without waiting and consults the safe root `.cleanup-last-run`
marker while holding that claim. A nonempty marker modified within 24 hours
throttles the pass. A busy skip leaves the marker untouched. The pass updates
the marker after inspecting the state root, including passes that preserve and
report unsafe entries. Explicit cleanup can immediately retry those entries.
Cleanup diagnostics do not change the command's normal execution result.

`AGENTLEASE_CLEANUP_KEEP_LOCK_DIGESTS` supplies comma-separated digest protections
for automatic passes. Its UTF-8 value is limited to 131,072 bytes and at most
1,024 digest entries. Integrations must include the idle descriptor and replay
references they still need in every automatic pass.

# Adoption boundary

Removal requires all processes that may acquire or re-establish ownership in
that state root to obey the permanent registry protocol. Stop older acquisitions
and ownership-establishing operations before the first destructive pass or
enabling automatic cleanup. Replacing a binary alone cannot retroactively
protect an already preopened waiter. Existing applications that already hold
resource flocks can remain running; cleanup preserves their inodes and records.

The automatic opt-in lets integrations establish that boundary and collect
evidence protections before allowing retirement. Ordinary execution with the
environment unset retains the previous no-automatic-removal behavior. New
acquisitions always use the registry protocol so later cleanup can run safely.

See [Locking core](locking-core.md) for descriptor lifetime rules and
[Verification map](verification.md) for retention regression coverage.
