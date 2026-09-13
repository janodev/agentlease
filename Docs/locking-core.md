---
type: Architecture
title: AgentLease locking core
description: Records the filesystem, descriptor, ordering, and persistence invariants implemented in Milestone 1.
tags: [agentlease, darwin, flock, locking]
timestamp: 2026-09-13T23:10:00+02:00
---

# Ownership model

`ResourceSet` validates the complete request before filesystem access and sorts
case-sensitive ASCII resource names by UTF-8 bytes. A lock filename is the
lowercase SHA-256 digest of the validated public resource name.

`LeaseSet` opens every persistent lock file before its monotonic wait budget
starts, then acquires in the shared sorted order with nonblocking `flock` calls.
Cancellation is checked before every attempt and after full acquisition. A
failed or cancelled partial acquisition closes acquired descriptors in reverse
order and closes every remaining opened descriptor.

After acquisition, `FileLock` duplicates its file description with
`F_DUPFD_CLOEXEC` at descriptor 64 or above and closes the original descriptor.
Production release closes the retained descriptor without calling `LOCK_UN`.
This is required so a supervised child or direct replacement can retain the
same kernel lock after the coordinator closes its reference.

# State safety

`AgentLeasePaths` obtains the default home from the effective-user account
database, ignores the mutable `HOME` environment variable, and distinguishes a
missing `AGENTLEASE_HOME` key from an explicitly empty value. It lexically
standardizes the selected root, canonicalizes only its existing parent, creates
only the final root, and rejects symlinks at the root, `locks`, or `runs`.

The root and managed directories are opened and retained with descriptor-relative
operations. Existing directories must be owned by the effective user with mode
`0700`; existing lock files must be regular, singly linked, user-owned files
with mode `0600`. New objects are explicitly corrected to their exact mode so a
restrictive process umask does not make them unusable. Persistent lock files are
never unlinked or replaced.

# Diagnostic persistence

Lock metadata is bounded to 4,096 bytes and rewritten in place only while the
lock is held. Its failure is collected as a diagnostic and never changes lock
ownership.

Run records use an exclusively created mode-`0600` temporary file in the
retained `runs` directory. The store writes completely, syncs the file, renames
within the directory, and syncs the directory. Injected write, file-sync,
rename, and directory-sync failures are covered by tests without exposing a
production command-line switch.
