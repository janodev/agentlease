---
type: Architecture
title: Shared resources and inherited descriptor manifest
description: Defines AgentLease 2 shared locking, schema changes, and the child descriptor contract.
tags: [agentlease, flock, shared-locks, descriptors, environment]
timestamp: 2026-09-14T12:00:00+02:00
status: implemented
---

# Version and compatibility

AgentLease 2.0.0 adds shared resource leases and versioned resource-mode fields.
The major version reflects run-record and status JSON schema changes from 1 to
2. The existing `--resource` spelling and behavior remain exclusive. Readers
of `LockMetadata` and `RunRecord` accept version-1 payloads and interpret their
resources as exclusive.

# CLI and acquisition contract

`run` and `exec` accept both repeatable options:

```text
--resource <name>         Acquire an exclusive lease.
--shared-resource <name>  Acquire a shared lease.
```

At least one option is required. The combined set has at most 64 names and its
sorted comma-separated representation has at most 4,096 UTF-8 bytes. Duplicate
names are rejected across and within modes. AgentLease validates the full set,
sorts it once by resource-name UTF-8 bytes, opens every persistent lock file,
and acquires that single order. Exclusive entries use `LOCK_EX | LOCK_NB`;
shared entries use `LOCK_SH | LOCK_NB`. Partial cleanup, deadlines, nested
execution rejection, descriptor duplication, and child inheritance apply to
both modes.

Shared owners never truncate or write the common lock file's diagnostic
metadata. Multiple shared writers would make the existing in-place metadata
format racy. Exclusive owners continue publishing metadata schema 2, whose
`leaseMode` field is `exclusive`. Run-record schema 2 retains the legacy sorted
`resources` array and adds sorted `resourceLeases` entries with `resource` and
`mode`; it therefore records shared ownership without mutating common metadata.

# Child descriptor manifest

After the complete set is acquired, both execution modes overwrite the reserved
`AGENTLEASE_LEASE_DESCRIPTORS` environment variable with compact JSON. Object
keys are emitted in sorted order and the `leases` array uses acquisition order:

```json
{"leases":[{"descriptor":64,"mode":"shared","path":"/canonical/root/locks/<sha256>.lock","resource":"example:cache"}],"schemaVersion":1}
```

The independent manifest schema has these invariants:

- `schemaVersion` is exactly `1`.
- `leases` contains 1 through 64 entries with strictly increasing, unique valid
  resource names and unique descriptor numbers at or above 64.
- `mode` is exactly `shared` or `exclusive`.
- `path` is the persistent absolute lock path, ends in the resource's SHA-256
  lock filename, has at most 4,096 UTF-8 bytes, and contains no C0 or C1 control
  scalars.
- The entire UTF-8 environment value has at most 131,072 bytes.

Base child-environment construction removes a stale inherited value. Manifest
encoding occurs while the leases are held and before a child starts; failure is
an environment/setup error with exit 70. In `run`, checked Darwin spawn actions
inherit only the listed close-on-exec descriptors. In `exec`, AgentLease clears
close-on-exec only on those descriptors before replacement. The manifest lets a
trusted child verify and transfer the exact inherited descriptors; it does not
grant ownership and is not a substitute for the open file descriptions.

For a protected child that must establish one inherited exclusive resource
before continuing, the hidden `verify-inherited-exclusive --resource <name>`
command validates an exact one-lease manifest, held-resource binding, canonical
state root, digest path, descriptor/path inode identity, ownership, link count,
and mode before applying `LOCK_EX | LOCK_NB` to that inherited open-file
description. The parent must retain another reference. This command is
deliberately single-resource: it cannot leave an earlier resource newly locked
when later validation fails. It provides kernel ownership for a cooperating
child; it does not authenticate which process originally acquired the lease.

`AGENTLEASE_HELD_RESOURCES` remains the nonempty nested-execution guard and
contains the same sorted resource names without mode information. Nested
`run`/`exec` remain forbidden even when all requested resources would be shared.

# Records and status

Run-record schema 2 adds `resourceLeases`. Lock-metadata schema 2 adds
`leaseMode`. Status schema 2 adds nullable `heldMode`, derived from `flock`
rather than metadata. Status first probes exclusive ownership. After contention,
it probes shared ownership; after a successful shared probe it attempts a
nonblocking exclusive upgrade. A successful upgrade means the previous holder
released between probes and reports `free`; a busy upgrade reports
`held`/`shared`; a busy shared probe reports `held`/`exclusive`.

Shared lock files commonly have absent metadata, or historical metadata from a
prior exclusive owner. Human output labels the kernel result as `held-mode` and
metadata mode separately as `last-owner-mode`.
