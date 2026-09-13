---
type: Architecture
title: Status inspection
description: Records the read-only kernel ownership probe and diagnostic metadata classifications.
tags: [agentlease, status, flock, json]
timestamp: 2026-09-14T00:00:00+02:00
status: implemented
---

# Authority and enumeration

`agentlease status` opens the validated state root and enumerates every entry in
the retained `locks` directory using descriptor-relative Darwin operations.
Names are sorted by their raw filename bytes. Only lowercase 64-character
SHA-256 digests followed by `.lock` are treated as expected lock names.

Each expected file is opened without following symlinks and must retain the
same regular-file, owner, link-count, and mode invariants as normal acquisition.
Status attempts `LOCK_EX | LOCK_NB` on a distinct file description. Successful
acquisition means `free`; `EWOULDBLOCK` means `held`; every other probe result is
`unknown`. The descriptor is closed without an explicit unlock. No status path
writes, truncates, renames, removes, repairs, or steals a lock.

Unexpected names and unsafe entry types remain untouched, appear as `unknown`,
and cause exit 70 after all inspectable entries have been reported. A held lock
is not an error.

# Metadata classification

Metadata reads are bounded to 4,096 bytes and never determine availability.
They are classified independently as `valid`, `absent`, `invalid`, `oversized`,
or `unreadable`. Valid metadata must decode as schema version 1, contain safe
bounded fields, and name a valid resource whose SHA-256 digest matches the
filename.

Invalid, missing, or oversized metadata leaves the kernel-derived `held` or
`free` result intact and does not change the exit code. Valid metadata on a
free lock is historical last-owner information. Human output labels that run as
historical; JSON consumers derive the same fact from `availability: "free"`
alongside `lastOwner`.

# Output contract

Default output is concise human-readable text. `--json` emits the independent
status schema version 1 with deterministic entry ordering and explicit nulls
for `digest`, `resource`, `lastOwner`, and `error` when absent. Entry and
directory failures use the same bounded structured failure shape as run
records. Directory-level enumeration failures also appear in the report's
top-level `errors` array.

Status remains available inside a leased command because it never consults the
nested-execution guard and never attempts to acquire a workflow lease.
