---
type: Architecture
title: AgentLease locking core
description: Records filesystem, descriptor, registry coordination, and persistence invariants.
tags: [agentlease, darwin, flock, locking]
---

# Ownership model

`ResourceSet` validates the complete shared and exclusive request before
filesystem access, rejects duplicate names across both modes, and sorts the one
combined set of case-sensitive ASCII resource names by UTF-8 bytes. A lock
filename is the lowercase SHA-256 digest of the validated public resource name.

`LeaseSet` starts its monotonic wait budget before cancellation-aware shared
registry admission, opens every resource file under that claim, then acquires
in the shared sorted order with nonblocking `flock` calls.
Exclusive leases use `LOCK_EX`; shared leases use `LOCK_SH`.
Cancellation is checked before every attempt and after full acquisition. A
failed or cancelled partial acquisition closes acquired descriptors in reverse
order and closes every remaining opened descriptor.

Each opened `FileLock` first obtains a shared claim on the permanent root
`.registry.lock`. It retains that claim while its resource descriptor is open
and awaiting acquisition, then closes the claim after successful ownership or
resource-descriptor closure. A preopened waiter therefore prevents cleanup from
unlinking the inode it will later lock. The execution commands also retain a
shared claim from before initial record publication through acquisition or
acquisition-failure publication. These internal claims remain close-on-exec and
never enter the inherited resource manifest.

After acquisition, `FileLock` retains the requested mode and persistent path,
then duplicates its file description with
`F_DUPFD_CLOEXEC` at descriptor 64 or above and closes the original descriptor.
Production release closes the retained descriptor without calling `LOCK_UN`.
This is required so a supervised child or direct replacement can retain the
same kernel lock after the coordinator closes its reference.
Successful acquisition refreshes the file timestamps before releasing the
pending registry claim, including shared acquisition without rewriting JSON.

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
restrictive process umask does not make them unusable. The root `.registry.lock`
is permanent and is never unlinked or replaced. Resource lock files keep their
inode through acquisition and ownership; coordinated cleanup may retire old idle
files only under the exclusive registry claim, an independent exclusive resource
flock, and a repeated descriptor/path identity check. See
[Coordinated retention](retention.md).

Each registry claim opens its own file description and releases it by closing.
Status holds a shared claim through enumeration and probes. Inherited exclusive
verification holds a shared claim through descriptor validation and `flock`.
Cleanup attempts its exclusive registry claim without waiting and skips a busy
registry. Resource ownership continues to depend on its own kernel flock.
Async acquisition admission polls nonblocking claims at most every 25 ms and
checks cancellation before attempts and after success. Synchronous inspection,
publication, inherited verification, and direct `FileLock` admission use a
bounded one-second wait, reporting a state-I/O failure if the registry stays busy.

# Diagnostic persistence

Lock metadata is bounded to 4,096 bytes and rewritten in place only while an
exclusive lock is held. Shared holders never mutate the common metadata file,
because multiple in-place truncate/write sequences would race. Metadata failure
is collected as a diagnostic and never changes lock ownership.

Every acquired set can produce the bounded, deterministic
`AGENTLEASE_LEASE_DESCRIPTORS` manifest described in
[Shared resources and inherited descriptor manifest](shared-resources.md).

Run records use an exclusively created mode-`0600` temporary file in the
retained `runs` directory. The store writes completely, syncs the file, renames
within the directory, and syncs the directory. Injected write, file-sync,
rename, and directory-sync failures are covered by tests without exposing a
production command-line switch.
The complete replacement operation holds a shared registry claim, excluding
cleanup while a temporary record is being written or renamed. JSON inode locks
cannot provide this exclusion because replacement changes the named inode.
