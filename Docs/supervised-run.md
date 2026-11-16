---
type: Architecture
title: Supervised run lifecycle
description: Records AgentLease run-mode validation, publication, inheritance, signal, and exit-precedence behavior.
tags: [agentlease, run, subprocess, signals]
timestamp: 2026-09-14T00:00:00+02:00
status: implemented
---

# Lifecycle

`agentlease run` validates raw UTF-8 arguments before ArgumentParser, validates
all resource and metadata fields, rejects a nonempty inherited
`AGENTLEASE_HELD_RESOURCES`, and resolves the executable before opening state.
It publishes `acquiring`, installs signal bridging, and acquires the complete
sorted resource set before a child can start.

After acquisition, the command publishes `acquired`, exports the canonical
state root, run correlation fields, and version-1 lease descriptor manifest,
and starts the exact caller argument array through Swift Subprocess. Standard
input is `/dev/null`; standard output and error remain attached to AgentLease's
caller. Every owned shared or exclusive descriptor stays `FD_CLOEXEC` in the
coordinator and is inherited only through checked Darwin spawn actions.

The child starts in a new session. Successful running publication records its
PID before AgentLease waits for termination. Terminal record publication and
best-effort terminal metadata for exclusive locks are attempted before the
coordinator closes its descriptors. Shared locks never mutate common metadata.

# Signal and failure behavior

`SIGINT`, `SIGTERM`, and `SIGHUP` are bridged through dispatch signal sources.
The first received signal cancels acquisition or supervised execution. Active
processes receive the configured process-group escalation and remain awaited
until reaped; the record stores the initiating signal without inventing a child
termination result when cancellation returns only `CancellationError`.

A failure to publish `running` occurs after spawn, so it triggers the same
teardown-and-reap path before locks are released. One bounded `failed`
publication is then attempted. A failure of terminal publication returns 70
only when the child succeeded; a nonzero child exit or signal-derived result
retains precedence.

Killing the coordinator with `SIGKILL` cannot finalize its record or supervise
cleanup. The child's inherited file descriptions intentionally retain the
kernel locks until the last inheriting process closes them. Records and lock
metadata may therefore remain historically `running`; neither is authority for
ownership.

# Regression coverage

Production executable tests cover exact `argv[0]`, argument privacy, null stdin,
environment reservations, exit and signal mapping, preflight and launch-time
errors, acquisition cancellation, process-group escalation with a descendant,
coordinator death, stale records, invalid raw UTF-8, and required publication
failure precedence.

The macOS 27 Foundation `Process.waitUntilExit()` API can stall in a combined
Swift Testing run after another task has already observed the process exit.
Async lifecycle tests use bounded monotonic `isRunning` polls and retain
`waitUntilExit()` only in synchronous short-lived cases. This is test-harness
policy and does not affect production child reaping, which remains owned by
Swift Subprocess.
