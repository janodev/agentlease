---
type: Implementation Brief
title: AgentLease implementation brief
description: Defines the macOS AgentLease CLI ownership contract and implementation milestones.
tags: [agentlease, macos, implementation]
---

# AgentLease implementation brief

Status: Milestones 0 through 2 implemented and verified; Milestones 3 and 4 pending

Date: 2026-09-13

## Objective

Build a small macOS command-line tool that lets cooperating coding agents run a
command while holding exclusive, named local resources. The operating system,
rather than conversational memory or a manually maintained registry, must be
the authority for whether a resource is currently owned.

The first useful invocation should look like this:

```sh
agentlease run \
  --resource notika:xcode-project-generation \
  --resource notika:derived-data:debug \
  --label "Select region tests" \
  --bead notika-62i.1.12.1.2.1 \
  -- make test-agent-development-control
```

If another cooperating process owns either resource, this invocation waits.
It starts the command only after it owns every requested resource, holds them
through child termination, reaping, and outcome recording, and then closes the
parent descriptors. An inheriting descendant may intentionally keep the kernel
lock after the direct child and AgentLease have exited.

This project is useful with Beads but must not depend on Beads. A Bead ID is
correlation metadata. AgentLease must not open, mutate, synchronize, or infer
authority from a `.beads` database.

## Why Swift

This is an Apple-development tool, so Swift is an acceptable deployment
constraint. Use Swift concurrency for orchestration and
[`swiftlang/swift-subprocess`](https://github.com/swiftlang/swift-subprocess/tree/1.0.0)
for supervised child execution. Pin the dependency to the released `1.0.x`
line, for example `.upToNextMinor(from: "1.0.0")`. AgentLease requires macOS 27
or later and Xcode 27 or later, with `// swift-tools-version: 6.4` and
`.macOS(.v27)` in `Package.swift`. State and enforce this baseline in the README
and CI. The dependency's older minimum requirements do not lower AgentLease's
deployment or toolchain requirements.

`swift-subprocess` should own process spawning, standard-stream routing,
termination observation, session creation, process-group teardown, and child
reaping. AgentLease should own resource identity, `flock` descriptors,
descriptor inheritance, acquisition ordering, run metadata, signal-to-task
bridging, and CLI policy.

Before building the complete CLI, compile a small spike against the selected
released package version that proves these exact APIs:

1. null stdin with inherited stdout/stderr;
2. child PID and termination status;
3. isolated session creation compatible with inherited lock descriptors;
4. process-group cancellation with explicit `toProcessGroup: true` steps;
5. Darwin `preSpawnProcessConfigurator` calling
   `posix_spawn_file_actions_addinherit_np` for a lock descriptor; and
6. byte-streaming output if optional log capture is attempted later.

The integration spike found that Swift Subprocess 1.0.0's
`PlatformOptions.createSession = true` takes its pre-fork path, where a retained
`FD_CLOEXEC` descriptor produces `EBADF` at spawn despite an explicit inherit
action. AgentLease must leave `createSession` false and atomically add
`POSIX_SPAWN_SETSID` to the spawn attributes in the same Darwin configurator that
adds descriptor inherit actions. This preserves direct `posix_spawn`, leaves the
coordinator descriptors close-on-exec, creates the required child session, and
allows `posix_spawn_file_actions_addinherit_np` to clear `FD_CLOEXEC` only in the
new process image. Keep the compiled regression tests and the evidence in
`Docs/subprocess-integration.md`; do not revert to the incompatible pre-fork path
without proving the dependency behavior changed.

## Scope of the first release

Implement these commands:

```text
agentlease run    Acquire resources and supervise one child command.
agentlease exec   Acquire resources and directly exec one command.
agentlease status Show the kernel-derived state and last-owner metadata.
```

Both execution commands accept:

```text
--resource <name>       Repeatable; at least one is required.
--label <text>          Optional human-readable description.
--bead <id>             Optional opaque correlation value.
--wait-seconds <value>  Optional monotonic acquisition deadline; default waits forever.
--record-arguments      Store the full argv in the run record; off by default.
-- <executable> [args]  Required; execute argv directly without an implicit shell.
```

Accept at most 64 resources and at most 4,096 bytes in their comma-separated
environment representation. Accept `--wait-seconds` only as a finite,
nonnegative number; absence means wait forever. When supplied, `label` and
`bead` must each contain 1 through 256 UTF-8 bytes. Reject a value containing a
Unicode scalar in the C0/C1 control ranges (`U+0000...U+001F` or
`U+007F...U+009F`) so it cannot corrupt environment values or terminal
diagnostics. Format characters outside those ranges remain valid, including the
zero-width joiner used in emoji sequences.

Start the monotonic wait budget immediately before the first lock attempt,
after validation, executable preflight, file opening, and initial record
publication. Check cancellation before every lock attempt, including zero-wait
attempts. Zero means a single nonblocking attempt at each resource, with no
retry: an entirely free set may still succeed. For a positive budget, check
cancellation and expiry before each attempt and bound polling delays by the
remaining budget. Saturate duration/deadline conversion rather than overflowing
for a very large finite value. The budget covers acquisition, not execution.
After the final successful attempt, check cancellation again before spawn.

Use a shell only when the caller explicitly supplies one, for example:

```sh
agentlease run --resource example:build -- zsh -lc 'make build && make test'
```

Use Swift Subprocess's public `Executable` resolution policy in both modes. A
command containing `/` is a path; resolve a relative path lexically against the
captured absolute working directory without resolving symlinks. Another command
is a name resolved from the child environment's `PATH`. The 1.0 policy searches
absolute PATH entries only, skips empty and relative entries, and uses the
system standard path if neither environment defines one. This deliberately
avoids current-directory PATH lookup. Pass `.path(resolvedPath)` to `run`, and
use the same absolute path with `execve` in direct mode.

Swift Subprocess normally installs the resolved path as child `argv[0]`. Preserve
the caller's exact array instead by constructing
`Arguments(executablePathOverride: command[0], remainingValues: Array(command.dropFirst()))`.
Pass that same original array to direct `execve`. Tests and the argument
commitment therefore describe identical argv semantics in both modes.

Version 1 supports command arguments that are valid UTF-8 byte sequences.
Validate the raw process `argv`, including `argv[0]`, before converting it to
Swift strings or invoking ArgumentParser. Reject an invalid sequence as a usage
error with exit code 64. This makes “exact argv” mean byte-for-byte preservation
of every accepted argument and gives the argument commitment the same domain in
both execution modes.

Resolve and preflight the executable before acquiring the first resource.
Subprocess's public resolver returns explicit paths unchanged without checking
existence. Check the resolved path for existence, regular-file type, and execute
permission using the effective credentials; executable symlinks are allowed.
Reject missing paths with 127 and non-regular or non-executable targets with 126.
Keep Subprocess's name-search policy: if no accessible PATH candidate is found,
return 127 even if an inaccessible candidate exists. Do not add a second PATH
search with different precedence.

Preflight is advisory with respect to the later spawn/exec race and does not
validate executable format or interpreter availability. Handle all launch errors
after ownership as well; an executable text file without a shebang may pass
preflight and then fail with 126 at launch. Do not attempt to interpret it.

Do not implement a daemon, distributed locks, network coordination, shared/read
locks, lock stealing, TTL ownership, automatic Xcode policy, automatic Beads
writes, or simulator allocation in the first release.

## Resource identity

Resource names are deliberate coordination contracts. AgentLease must not infer
them from the current directory or command.

For version 1, accept case-sensitive ASCII names matching:

```text
[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}
```

Reject empty, malformed, duplicate, or excessively long names. Sort the
validated names by their UTF-8 bytes before acquiring any lock. This gives all
processes the same multi-lock order and prevents the ordinary A-then-B versus
B-then-A deadlock.

Use lowercase hexadecimal SHA-256 of the exact resource-name UTF-8 bytes as its
64-character lock filename. Store the readable name in metadata. Hashing is a
path representation only; the original validated name is the public identity.

Examples:

```text
host:macos-ui
notika:xcode-project-generation
notika:derived-data:debug
notika:derived-data:release
workspace:4f98...:beads-writer
```

Project tooling is responsible for using the same name for the same shared
resource. Resources are local to one user account on one host.

## State directory and file safety

Use this root:

```text
$AGENTLEASE_HOME                  when explicitly set
~/.agentlease                    otherwise
```

Create this layout:

```text
~/.agentlease/
  locks/
    <sha256>.lock
  runs/
    <run-id>.json
```

Create directories as mode `0700` and regular files as mode `0600`. Lock files
are persistent and must never be unlinked during normal operation, cleanup, or
schema migration. Replacing or unlinking a lock file can split ownership across
two inodes, allowing two callers to believe they own the same resource.

Treat `AGENTLEASE_HOME` as explicitly set when the environment contains the key,
including when its value is empty. An explicitly set value must be a nonempty
absolute path. When the key is absent, obtain the effective user's home directory
from the account database with `getpwuid_r(geteuid())` and append `.agentlease`;
do not derive the default from the mutable `HOME` environment variable. Fail
with exit code 70 if the account home cannot be determined.

Lexically standardize the selected absolute path. Require its immediate parent
to exist as a directory, resolve that parent with `realpath`, then append the
unchanged final path component. Create only that final root when absent; do not
recursively create or assign policy to ancestors outside AgentLease. Export this
canonical-parent-plus-final-component path as the actual root used by the
current process. Do not resolve the final component itself, because an existing
symlink at the AgentLease root must be rejected rather than followed. This keeps
a child's different working directory or `HOME` value from selecting another
lock namespace.

Open lock paths with protections appropriate to Darwin, including `O_NOFOLLOW`
and `O_CLOEXEC`, then use `fstat` to require a regular file owned by the current
effective user, with one hard link and permission mode exactly `0600`. Fail
closed for symlinks, directories, hard-linked files, unexpected ownership,
unsafe modes, or inaccessible paths. Require existing AgentLease directories to
be owned by the effective user with mode exactly `0700`. Do not silently repair
an unsafe existing path.

Open the root itself and its `locks/` and `runs/` children as directories with
`O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`, and validate each opened descriptor with
`fstat`. Reject a symlink at any of these three AgentLease-owned locations.
Existing ancestors outside the root may contain system symlinks (for example
`/var`); resolve the parent before opening or creating the root. Do not require
ancestors outside AgentLease's root to have mode `0700`.

Retain the validated directory descriptors for the operation. Use `openat`,
`mkdirat`, and `renameat` relative to those descriptors for managed entries,
and sync the retained `runs/` descriptor after record replacement. Create
temporary records exclusively and never follow an existing temporary path.
Directory creation must handle a concurrent creator by opening and validating
the resulting directory. Ensure exact modes on newly created objects even under
a restrictive umask; do not chmod pre-existing objects. Replacing or relocating
the root or its managed directories during use is outside the cooperative
contract, just as replacing a persistent lock file is.

`AGENTLEASE_HOME` exists for isolated tests. Production commands that need to
coordinate must use the same root.

## Kernel lock contract

Use Darwin `flock` with `LOCK_EX | LOCK_NB`. A Swift owner object retains each
open descriptor. Acquisition should poll asynchronously with a monotonic clock
and a short bounded delay; do not block a Swift cooperative executor on a
potentially indefinite system call.

After a successful lock, move the descriptor out of the low application range
with `fcntl(F_DUPFD_CLOEXEC, 64)` and close the original descriptor. Retain the
returned descriptor. Check `RLIMIT_NOFILE` and fail cleanly if the requested set
cannot fit; never reuse or overwrite an unrelated open descriptor. This reduces
the chance that an executed program assigns a conventional meaning to an
inherited lock descriptor. It does not prevent a program from intentionally
closing all unknown descriptors, which remains outside the cooperative contract.

Required acquisition algorithm:

1. Validate every requested resource, reject duplicates, and sort the set.
2. Open all corresponding persistent lock files safely.
3. Acquire each lock in sorted order.
4. If one is busy, retain already acquired lower-ordered locks while waiting.
   Because every client uses the same order, this cannot form a lock cycle.
5. When each lock is acquired, write best-effort owner metadata containing the
   run ID and `acquiring` state while that descriptor is held.
6. If the deadline, task cancellation, or an error stops acquisition, close
   every acquired descriptor in reverse order and every opened but unacquired
   descriptor. Never leave an opened descriptor behind on a failed duplication.
7. Start no child unless the complete set is owned.
8. After complete ownership, update the lock metadata and run record to the
   `acquired` state.
9. Keep every parent descriptor open through child reaping and run-record
   finalization. Then close in reverse order.

The descriptor and `flock`, not JSON, PID existence, timestamps, labels, or
Bead state, are ownership authority. Metadata can be stale after a crash and
must be described as the last observed owner.

Do **not** call `flock(fd, LOCK_UN)` when releasing production ownership. Darwin
defines duplicated and fork-inherited descriptors as references to one lock; an
explicit unlock through any reference removes that lock for every reference.
AgentLease deliberately gives the child such a reference. Closing the parent's
descriptors without `LOCK_UN` lets an inherited child or descendant keep the
lock, and kernel cleanup releases it after the last reference closes.

The lock owner type should provide explicit `release()` plus a `deinit` fallback,
where release consumes/closes the descriptor without unlocking it first.
Correct paths must call `release()`; tests must not rely only on ARC timing.
Status probes should follow the same close-without-unlock rule for consistency.

## Nested invocation policy

Export the sorted resource names in `AGENTLEASE_HELD_RESOURCES` and the resolved
state root in `AGENTLEASE_HOME` to the child. Because the resource grammar
excludes commas, a comma-separated resource representation is sufficient for
version 1. Do not export lock descriptor numbers.

Build the child environment from the inherited environment, overwriting
`AGENTLEASE_HOME`, `AGENTLEASE_RUN_ID`, and `AGENTLEASE_HELD_RESOURCES` for this
invocation. Set `AGENTLEASE_BEAD_ID` only when `--bead` is supplied; otherwise
remove any inherited value so stale correlation metadata cannot leak into a
new run. Apply the same rules in both execution modes.

If `AGENTLEASE_HELD_RESOURCES` is already nonempty, a nested `run` or `exec`
must fail with exit code 70 immediately after argument and raw-UTF-8 validation,
before generating a run ID, resolving the executable, opening or creating state,
or acquiring anything. Treat whitespace and malformed values as nonempty; the
child must not trust or parse the inherited list to decide that nesting is safe.
Even disjoint nested acquisition can create a lock cycle across two parent
workflows. Read-only `status` remains allowed. Do not add a reentrant or nested
execution escape hatch until there is a separately specified ordering protocol
across nesting levels.

Layering AgentLease around SimLease is valid because SimLease is a separate lock
authority and command, rather than a nested AgentLease invocation.

## `run`: supervised execution

`run` is the observable, noninteractive mode. Use `swift-subprocess` with null
stdin and inherited stdout/stderr. Null stdin prevents an unattended build from
hanging on a prompt and avoids falsely promising terminal job-control semantics
after the child enters its own session. Use `exec` for an interactive shell or a
command that must read the terminal. Do not capture or buffer ordinary output by
default.

Open the parent lock descriptors with `O_CLOEXEC`. In the subprocess Darwin
configuration, add each owned descriptor to the spawn file actions with
`posix_spawn_file_actions_addinherit_np`. Check every return code and fail before
spawn if any action cannot be installed. Swift Subprocess 1.0 uses
`POSIX_SPAWN_CLOEXEC_DEFAULT`, so this explicit file action is necessary.
The `@Sendable` configurator may capture immutable raw descriptor values, but the
owning `LeaseSet` must remain strongly retained until spawning has completed and
through the rest of the supervised lifecycle.

This inheritance is the supervised mode's crash-safety lifeline. The parent and
child refer to the same kernel lock. If the supervisor is killed, the command
keeps ownership until it and all inheriting descendants close their copies. Do
not clear `FD_CLOEXEC` on arbitrary descriptors and do not expose descriptor
numbers in environment or metadata.

After acquiring every lock:

1. Atomically persist an `acquired` record with no child PID.
2. Export `AGENTLEASE_RUN_ID`, `AGENTLEASE_HELD_RESOURCES`, and optional
   `AGENTLEASE_BEAD_ID` to the child without deleting its inherited environment.
3. Leave `PlatformOptions.createSession` false, configure every teardown step
   with `toProcessGroup: true`, and install `POSIX_SPAWN_SETSID` through the
   Darwin configurator.
4. In that configurator, preserve the existing spawn flags, add the session flag
   and every Darwin inherit action with checked return codes, then spawn the
   exact argv without an implicit shell.
5. Atomically replace the record with `running` and the child PID, then update
   the best-effort lock metadata to the same state.
6. Wait for termination and let Swift Subprocess reap the child.
7. Atomically replace the record with its terminal outcome.
8. Close the parent's lock descriptors only after terminal record persistence
   succeeds or its failure has been reported clearly. Never explicitly unlock
   them.

If publishing `running` fails after spawn, initiate the configured teardown and
await reaping before attempting a `failed` record and releasing descriptors.
Return 70 unless a received signal supplies the signal-derived result. A record
error must never detach a still-running child from supervision. Failure-record
publication can itself fail: report both errors without recursive retries.

Before closing the parent's descriptors, best-effort update each lock's metadata
to the terminal `exited`, `signalled`, or `failed` state recorded for the run.
If terminal run-record publication failed, use the terminal state that would
have been recorded. This improves historical status output without making the
metadata authoritative.

Install safe signal bridging for `SIGINT`, `SIGTERM`, and `SIGHUP` before lock
acquisition starts. The first signal cancels the root operation: partial lock
acquisition closes immediately, while an active subprocess uses the configured
teardown and remains awaited until reaped. Remember the first received signal
for the CLI result. Restore the process's prior signal dispositions when
supervised execution finishes.

Use `DispatchSourceSignal` or an equivalent async-safe bridge; do not execute
Swift allocation, locking, or task APIs from a C signal handler. Make signal
delivery terminal-once so simultaneous signals cannot start competing teardown
tasks. Confirm in the integration spike that Swift Subprocess resets the child's
signal dispositions to defaults before execution.

Use this Swift Subprocess teardown sequence:

```text
.send(.interrupt, toProcessGroup: true); wait up to 2 seconds
.gracefulShutDown(toProcessGroup: true); wait up to 5 seconds
implicit final SIGKILL to the process group; wait until reaped
```

Swift Subprocess 1.0 documents and tests that its implicit final kill inherits
the last explicit step's process-group choice. Keep an AgentLease integration
test with a grandchild because the correctness claim belongs to this executable,
not only its dependency.

Return the child's normal exit status. If the child dies from a signal, return
the conventional `128 + signal`. If AgentLease received a catchable signal,
return `128 + firstReceivedSignal` after reaping and finalization, regardless of
which teardown signal eventually stopped the child.

If AgentLease is killed with `SIGKILL`, it cannot forward a signal, finalize the
record, or reap its child. The inherited descriptors are specifically required
so a surviving child still prevents a new owner from entering. Metadata and the
`running` record may remain stale; `status` must still report the held kernel
lock. A command that deliberately closes or unlocks unknown inherited
descriptors is outside the cooperative contract and can defeat this lifeline.

The command may spawn a descendant that leaves the created process group. If it
inherits a lock descriptor, the lock remains held even after `run` returns. That
is safer than permitting overlap. `status` will show the resource held with the
last run metadata; AgentLease has no lock-stealing recovery path.

## `exec`: inherited-descriptor execution

`exec` mirrors the useful ownership shape of `simlease macos-ui`:

1. Validate the command and resolve its executable before acquiring locks.
2. Acquire all resources and write the `acquired` record.
3. Export the AgentLease environment fields.
4. Clear `FD_CLOEXEC` only on the owned lock descriptors.
5. Write a `handoffPrepared` record and matching best-effort lock metadata
   immediately before replacement.
6. Call Darwin `execve` with the resolved executable, exact argv, and updated
   inherited environment, while preserving the caller's
   stdin/stdout/stderr and terminal process group.

The requested executable replaces AgentLease and directly inherits the locks.
Its exit code and signals require no translation. Kernel cleanup releases the
locks when the last process holding inherited descriptors exits, including after
ordinary process death. Descendants may inherit the descriptors; this is the
intended full-workflow boundary, but the README must warn that an accidental
background descendant can retain a lock longer than expected. An executable can
also deliberately close unknown descriptors, so state the contract as POSIX
descriptor inheritance rather than an absolute guarantee about hostile code.

Because AgentLease no longer exists after successful `execve`, the run record
cannot receive a confirmed handoff or child terminal outcome. `handoffPrepared`
truthfully says only that AgentLease completed preparation and was about to call
`execve`; a signal or crash can still intervene. `status` derives current
ownership from `flock`, not that record. Do not use `execvp`: Darwin may invoke
`/bin/sh` implicitly after `ENOEXEC`, which would violate the explicit-shell
contract. If environment preparation or `execve` fails, replace the record with
`failed`, report the exact error, close the lock descriptors without explicitly
unlocking them, and apply the shared exit-code policy: executable launch errors
use 126 or 127 as specified below; environment and other setup errors use 70.
If publishing the required failure record also fails, report both errors and
return 70 because no child started.

On `execve` failure, best-effort update the lock metadata to `failed` after
attempting the required failed run record and before closing the descriptors.

Before replacement, `exec` keeps ordinary signal dispositions. A signal while
waiting or preparing may terminate AgentLease and leave an `acquiring`,
`acquired`, or `handoffPrepared` record stale, while kernel descriptor closure
still releases its ownership. Do not install a relay that changes the eventual
executed command's terminal signal behavior.

## Run records

Generate the UUID run ID and write an `acquiring` record before taking the first
lock. Replace it with `acquired`, `running`, and a terminal state as the workflow
advances. A crash may leave any earlier state behind; records describe last
published knowledge and never grant or revoke ownership.

Write JSON through a uniquely created mode-`0600` temporary file in `runs/`,
call `fsync` on the file, rename it atomically over the destination, and `fsync`
the containing directory. Check every operation. If full power-loss durability
is claimed on macOS, separately justify and test whether `F_FULLFSYNC` is
required; otherwise call the contract atomic replacement with checked syncing,
rather than unconditional durable storage. Version the schema from the first
commit.

Suggested version-1 shape:

```json
{
  "schemaVersion": 1,
  "runID": "UUID",
  "mode": "run",
  "state": "exited",
  "resources": ["notika:derived-data:debug"],
  "label": "Select region tests",
  "bead": "notika-62i.1.12.1.2.1",
  "coordinatorPID": 1234,
  "childPID": 1235,
  "workingDirectory": "/absolute/path",
  "executable": "make",
  "resolvedExecutable": "/usr/bin/make",
  "argumentCommitment": "sha256-of-length-prefixed-argv",
  "arguments": null,
  "startedAt": "RFC3339 timestamp",
  "finishedAt": "RFC3339 timestamp",
  "receivedSignal": null,
  "termination": { "kind": "exit", "value": 0 },
  "failure": null
}
```

Allowed states are `acquiring`, `acquired`, `running`, `exited`, `signalled`,
`failed`, and `handoffPrepared`. `childPID` and `finishedAt` are nullable before
their respective transitions. `handoffPrepared` is an exec-attempt witness, not
proof that process replacement succeeded.

Use these terminal transition and result rules:

| Event after initial record publication | Required terminal record | CLI result |
|---|---|---|
| Acquisition deadline expires | `failed`, `finishedAt` set, `termination` null, bounded failure kind `acquisitionTimeout` | 75 |
| Supervised acquisition receives a bridged signal | `signalled`, `finishedAt` and `receivedSignal` set, `termination` null | `128 + signal` |
| Supervised task cancellation without a recorded signal | `failed`, `finishedAt` set, `termination` null, failure kind `cancelled` | 70 |
| Storage, lock, environment, or other setup fails | `failed`, `finishedAt` set, `termination` null, bounded failure details | 70 |
| Spawn or `execve` rejects the executable | `failed`, `finishedAt` set, `termination` null, bounded executable failure | 126 or 127 by errno |
| `run` child exits normally | `exited`, `finishedAt` and exit `termination` set | child exit status |
| `run` child dies from a signal without coordinator cancellation | `signalled`, `finishedAt` and signal `termination` set, `receivedSignal` null | `128 + child signal` |
| `run` cancellation completes with only `CancellationError` | `signalled`, `finishedAt` and `receivedSignal` set, `termination` null | `128 + receivedSignal` |
| Publishing `running` fails after spawn | Tear down and reap, then write `failed` with publication failure; leave `termination` null when no result is available | 70, or `128 + receivedSignal` |

Validation, nesting rejection, executable preflight, state initialization, or
initial `acquiring` publication can fail before a run record exists. Do not
create a retrospective record for such failures. If a later required transition
fails, make one bounded attempt to publish `failed`, except when the failed
transition was already the terminal publication. Report every publication
error. Never recursively retry a failed failure record.

Store `executable` as the caller's original `argv[0]` and
`resolvedExecutable` as the path actually supplied to spawn or `execve`.
Use a bounded structured `failure` value for AgentLease setup, acquisition,
spawn, and record-publication errors; do not put arbitrary child output in it.

A version-1 structured failure has exactly these keys, retaining null values:

```json
{
  "kind": "acquisitionTimeout",
  "operation": "flock",
  "errno": null,
  "resource": "example:build",
  "message": "timed out waiting for the resource"
}
```

`kind` is one of `acquisitionTimeout`, `cancelled`, `unsafeState`, `stateIO`,
`lockIO`, `resourceLimit`, `environment`, `executableNotFound`,
`executableNotRunnable`, `spawn`, `exec`, `recordPublication`, or `internal`.
`operation` is a stable short operation name, `errno` contains the Darwin errno
when applicable, and `resource` identifies the affected public resource when
applicable. Limit each string to 512 UTF-8 bytes and replace C0/C1 control
scalars in system-provided messages before persistence or display. Diagnostics
may add path and contextual detail on stderr, but records and status JSON must
not acquire ad hoc keys.

When a child exits independently, store its observed exit or signal in
`termination`. When cancellation of the Swift task triggers dependency-managed
teardown, Swift Subprocess 1.0 can throw `CancellationError` after cleanup
instead of returning `ExecutionResult`; in that case store the initiating value
in `receivedSignal`, use state `signalled`, and leave `termination` null rather
than inventing the final child signal. Publication of that terminal record occurs
only after the awaited run call has completed its teardown/reaping path.

Compute `argumentCommitment` as SHA-256 over the ASCII domain bytes
`agentlease.argv.v1` followed by one NUL byte, then each argv value as an
unsigned 64-bit big-endian byte count followed by its UTF-8 bytes. Include
`argv[0]`; never hash a space-joined command. Persist full `arguments` only with
`--record-arguments`. Never persist the inherited environment because it
commonly contains credentials. The commitment establishes equality only; it is
not authentication and does not conceal a guessable secret supplied as an
argument.

Lock-file metadata should contain only schema version, resource name, run ID,
coordinator PID, optional child PID, mode, state, label, Bead ID, and acquisition
time. It is diagnostic data and need not duplicate the full run record. Limit
its encoded size and every status read to 4,096 bytes. Treat a partial,
oversized, or invalid value as unavailable; replacing a lock file to make
metadata atomic is forbidden. While holding the lock, rewrite in place with a
checked truncate and complete positional write; a crash may still leave partial
diagnostic bytes without affecting kernel ownership.

“Best-effort” means a metadata encoding, truncation, or write failure never
prevents acquisition, launch, teardown, or descriptor release and never changes
the CLI result. Aggregate failures from one lifecycle transition into one
bounded stderr diagnostic. Continue to check every operation so failures are
observable. Run-record writes remain required and follow the separate precedence
rules above.

## `status`

`agentlease status` enumerates persistent lock files. For each valid file:

1. Open and validate it safely.
2. Attempt `LOCK_EX | LOCK_NB`.
3. If acquisition succeeds, read bounded metadata while the probe lock is held,
   close the descriptor, and report `free` plus any decodable last-owner data.
4. If `EWOULDBLOCK`, read only a bounded payload and report `held` plus
   best-effort metadata; concurrent owner writes may make it temporarily
   undecodable.
5. Treat other probe errors as `unknown` and report the error; never call the
   resource free merely because metadata is absent or corrupt.

When metadata supplies a resource name, validate it and require its SHA-256 to
match the lock filename before displaying it as that resource. Otherwise show
the filename digest and label the metadata invalid. A held lock with unreadable
metadata is still held.

Offer human-readable output by default and `--json` for automation. `status`
must not rewrite, unlink, repair, or steal locks. Held resources are a successful
status result. Return 70 if any enumerated lock cannot be safely opened or
probed, while still reporting all entries that could be inspected.

Enumerate every entry in `locks/` except `.` and `..`, sorted by filename UTF-8
bytes. A valid lock filename matches `[0-9a-f]{64}\\.lock`. Represent an
unexpected filename or non-regular entry as `unknown` with an entry error, leave
it untouched, continue enumeration, and return 70 after reporting all results.
A metadata status other than `valid` does not by itself make kernel ownership
unknown and does not change the exit code.

Version JSON output independently from run records and use this shape. Emit
nullable keys rather than omitting them so automation receives one stable
schema. `lastOwner` uses exactly the bounded lock-metadata fields described
above. `metadataStatus` is `valid`, `absent`, `invalid`, `oversized`, or
`unreadable`. `error` and top-level `errors` use the same bounded structured
error shape as run records. Metadata errors stay on the entry; directory
enumeration errors also appear in the top-level list.

```json
{
  "schemaVersion": 1,
  "stateRoot": "/Users/example/.agentlease",
  "entries": [
    {
      "fileName": "0123...cdef.lock",
      "digest": "0123...cdef",
      "resource": "example:build",
      "availability": "held",
      "metadataStatus": "valid",
      "lastOwner": {
        "schemaVersion": 1,
        "resourceName": "example:build",
        "runID": "UUID",
        "coordinatorPID": 1234,
        "childPID": 1235,
        "mode": "run",
        "state": "running",
        "label": null,
        "bead": null,
        "acquiredAt": "RFC3339 timestamp"
      },
      "error": null
    }
  ],
  "errors": []
}
```

Use `digest: null`, `resource: null`, and `availability: "unknown"` for an
unexpected directory entry. For a valid lock filename with absent or invalid
metadata, retain its digest, set `resource` and `lastOwner` to null, and report
the kernel-derived availability. Human output must preserve the same distinctions
without promising a stable whitespace layout.

If a resource remains held after its coordinator PID has disappeared, assume an
inherited child or descendant still owns the file description. Operational
recovery is to identify the process with `lsof` on the persistent lock path and
terminate that workload. Never delete the lock file: deletion does not revoke
the old inode lock and would let a new process lock a replacement inode.

## Exit codes and diagnostics

Use predictable codes:

```text
child exit          preserve the child status
child signal        128 + signal
command not found   127
not executable      126
usage error         64
lock wait timeout   75
internal/setup      70
```

Map missing PATH candidates and executable `ENOENT`/`ENOTDIR` failures during
preflight or launch to 127, including an interpreter missing at launch.
Map a resolved candidate rejected with `EACCES`, `EPERM`, or `ENOEXEC` to 126;
in particular, do not interpret `ENOEXEC` through a shell. Reserve 70 for an
AgentLease failure such as unsafe storage, corrupt required state, spawn
infrastructure, or record publication.

Apply these errno mappings only to executable resolution/preflight/launch.
The same errno from state storage is an AgentLease setup failure, not a missing
or non-executable command.

If terminal record publication fails after a child outcome exists, report that
failure on stderr. Preserve a nonzero child or signal-derived status; return 70
for the publication failure only when the child otherwise succeeded. Before a
child starts, any required run-record failure prevents spawn and returns 70.

Write AgentLease diagnostics to stderr. On first contention, print which
resource is busy and the last-owner label/run ID when safely decodable. Avoid
repeated noisy polling output; one waiting message and one acquisition message
are enough.

## Suggested package layout

```text
Package.swift
README.md
Sources/
  AgentLeaseCore/
    ResourceName.swift
    AgentLeasePaths.swift
    FileLock.swift
    LeaseSet.swift
    RunRecord.swift
    AtomicJSONStore.swift
    StatusProbe.swift
    ArgumentCommitment.swift
    ExecutableResolver.swift
  agentlease/
    AgentLeaseCommand.swift
    RunCommand.swift
    ExecCommand.swift
    StatusCommand.swift
    SignalRelay.swift
    main.swift
Tests/
  AgentLeaseCoreTests/
  AgentLeaseCLITests/
```

Use `swift-argument-parser` for CLI parsing and Swift Testing for new tests.
Keep Darwin-specific calls behind small types that can be exercised by real
subprocess tests. Start as macOS-only; cross-platform support can be considered
after the Darwin ownership contract is complete.

## Required tests

Unit tests alone are insufficient for descriptor ownership. Add real subprocess
tests with isolated `AGENTLEASE_HOME` directories.

1. Two processes requesting the same resource never overlap their critical
   sections.
2. Processes requesting different resources can overlap.
3. Requests listing A/B and B/A acquire in the same order and complete without
   deadlock.
4. A timeout or cancellation during the second acquisition releases the first.
5. Normal exit and nonzero exit close the parent's descriptors and preserve
   status; with no surviving inherited descendant, the locks become free.
6. A child that ignores `SIGINT` receives escalation and is reaped before the
   next waiter enters.
7. A spawned grandchild is terminated by supervised process-group teardown.
8. Killing a supervised coordinator with `SIGKILL` demonstrates and documents
   that a surviving child retains the lock; the next waiter enters only after
   that child exits or closes its inherited descriptor.
9. `exec` retains ownership after process replacement and releases it on normal
   exit and signal death.
10. A descendant inheriting an `exec` lock keeps it held until the descendant
    exits.
11. Nested `run` and `exec` fail immediately without acquiring a lock, while
    nested `status` remains usable.
12. Symlink, directory, wrong-owner where testable, and corrupt-metadata cases
    fail closed without replacing lock paths.
13. A stale `running` record never prevents acquisition when the kernel lock is
    free.
14. `status` reports held/free from real lock probes and labels stale metadata
    as historical.
15. Full argv is absent by default, its length-prefixed commitment is stable,
    and `--record-arguments` stores it exactly.
16. Supervised stdin is EOF, stdout/stderr remain attached to the caller, and
    `exec` retains interactive standard streams.
17. Signal receipt during supervised `run` acquisition releases every partial
    descriptor and records a signal-derived outcome without spawning a child;
    direct `exec` acquisition retains ordinary signal termination behavior.
18. Both modes skip relative and empty PATH entries; a text file without a
    shebang fails with 126 and is never interpreted by `/bin/sh`.
19. Command-not-found returns 127, while unsafe-state and record failures use
    the documented AgentLease precedence and return 70 only where specified.
20. Retained lock descriptors use freshly duplicated values at or above 64 and
    remain `FD_CLOEXEC` in the coordinator until direct mode deliberately clears
    that flag for handoff. Inheritance uses only the two documented execution
    paths.
21. A signal-cancelled supervised run records the received signal and does not
    invent an actual child termination status when Swift Subprocess returns only
    `CancellationError` after teardown.
22. Explicit missing, directory, and non-executable command paths fail preflight
    before any lock is acquired; launch-time format/interpreter failures use the
    same executable error mapping in both modes.
23. Zero wait succeeds for a free set and fails immediately for a busy set;
    positive deadlines cover the whole set and huge finite values do not trap.
24. Root and managed-directory symlinks fail closed; concurrent safe directory
    creation succeeds, and a restrictive umask does not produce unusable state.
25. Both modes overwrite reserved environment fields and remove a stale Bead ID
    when no `--bead` is supplied, preserving unrelated environment fields.
26. Injected `running` record publication failure tears down and reaps the child
    before parent descriptor release; failed failure-record publication reports
    both errors and obeys exit-code precedence.
27. Default-root selection ignores a conflicting `HOME`; explicit empty,
    relative, missing-parent, and root-symlink paths fail as specified. Invalid
    raw UTF-8 argv and text-field control bytes are rejected deterministically.
28. Status JSON has stable nullable fields and filename ordering; unexpected
    directory entries produce `unknown` results and exit 70, while corrupt or
    absent metadata preserves the kernel result without changing the exit code.
29. Metadata write failures are reported but never prevent child launch or alter
    its result, and supervised terminal metadata is attempted before descriptor
    release.

Tests that coordinate subprocesses should use pipes or explicit marker files,
bounded monotonic deadlines, and diagnostic process output. Avoid fixed sleeps
as the main synchronization mechanism.

## Implementation milestones

### Milestone 0: package and Subprocess integration spike

Create the Swift 6.4 package targeting macOS 27 and a root Makefile with build
and test targets. Resolve and check in the selected 1.0.x dependency version.
Compile and run the integration spike described above before designing the
complete CLI. Prove inherited lock retention after coordinator `SIGKILL`, child
signal defaults, session creation through `POSIX_SPAWN_SETSID`, process-group
escalation with a grandchild, and awaited reaping after cancellation. Keep the
helper and these proofs as regression tests.
Optional byte-stream capture is not a prerequisite for version 1.

Completion gate: the spike builds and its process tests pass on macOS 27/Xcode
27. Record the exact resolved package version and compiled API usage in concise
OKF documentation under `Docs/`, linked from `Docs/index.md`. If any ownership
or teardown proof fails, resolve that failure before proceeding with the CLI.

### Milestone 1: locking core

Implement resource validation, safe paths, `FileLock`, ordered
`LeaseSet`, atomic JSON storage, and real contention tests. A tiny test helper
executable may hold locks and exchange pipe markers before the production CLI
exists.

Completion gate: real contention, ordered multi-lock acquisition, partial cleanup,
descriptor inheritance, storage rejection, and atomic record replacement tests
pass. Include injected write/rename/sync failures without exposing failure
injection switches in the production CLI.

### Milestone 2: supervised `run`

Build on the verified `swift-subprocess` spike: implement shared executable
resolution, argument commitment, run records, null stdin with inherited output
streams, inherited lock descriptors, environment export, process-group signal
teardown, exit mapping, and executable integration tests.

Completion gate: `run` preserves argv and exit outcomes, rejects nesting, handles
signals during acquisition and execution, and retains ownership through reaping
and finalization. Supervisor-death and record-failure tests must exercise the
production executable as well as the spike helper.

### Milestone 3: direct `exec`

Implement exact descriptor inheritance and `execve` using the shared resolver,
environment builder, records, and error mapping. Add replacement,
descendant-lifetime, crash, signal, and exit-preservation tests.

Completion gate: direct replacement preserves terminal streams and exact argv,
records only `handoffPrepared` on successful replacement, and retains ownership
until the last inheriting descriptor closes. Failure cases obey the shared
126/127/70 policy without invoking a shell implicitly.

### Milestone 4: status and documentation

Implement authoritative probes, JSON output, installation instructions,
examples for Make and Beads-oriented workflows, operational limits, and a short
comparison of `run` and `exec`.

Completion gate: status reports all inspectable entries, gives kernel-derived
held/free/unknown results even with corrupt metadata, and never changes lock
contents. All 29 required test scenarios and the definition of done pass.
Document installation from the built release binary and macOS 27 CI execution;
do not introduce Xcode project generation for this command-line Swift package.

### Implementation boundaries

Keep resource validation, paths, descriptors, record persistence, status probes,
argument commitments, and executable resolution in `AgentLeaseCore`. The CLI
owns parsing, lifecycle sequencing, signal bridging, child environment assembly,
and exit-code precedence. Reuse the shared core in both execution modes so
their resource and argv semantics cannot diverge.

Use a small subprocess test helper for readiness markers, inherited-descriptor
checks, controlled signal handling, and descendant creation. Each test owns an
isolated state root, bounded waits, and explicit teardown of its processes.
These CLI tests need no desktop UI or Simulator interaction. Any later test that
does interact with those surfaces must follow the applicable SimLease workflow.

The implementation handoff ends at this standalone CLI. Changes to Notika,
SimLease, Beads databases, and existing build workflows are outside these
milestones.

## Definition of done

The first release is complete when:

- all required real-subprocess tests pass repeatedly without timing flakes;
- no path removes or replaces a persistent lock file;
- no child starts with only a partial resource set;
- supervised cancellation always waits for reaping before closing the parent's
  lock descriptors;
- supervised children inherit every owned lock, and supervisor `SIGKILL` does
  not admit a waiter while the child retains those descriptors;
- direct mode proves descriptor ownership across `exec`;
- status derives ownership from `flock` and labels metadata as diagnostic;
- nested invocation fails before it can deadlock;
- exact child exit behavior and documented signal-derived behavior are tested;
- the README states the Swift/Xcode requirement, supervised noninteractive
  stdin contract, inherited-descriptor behavior, and stale-record limit after
  supervisor `SIGKILL`; and
- the root Makefile's build and test targets (wrapping `swift build` and
  `swift test`) and `git diff --check` pass. Do not introduce SwiftFormat or
  SwiftLint; keep imports alphabetically sorted.

## Local reference implementations

Inspect these local sources before implementing, while keeping AgentLease a
separate generic tool:

- `/Users/jano/Developer/code/janodev/simlease/Docs/current-architecture.md`
- `/Users/jano/Developer/code/janodev/simlease/Docs/macos-ui-lock.md`
- `/Users/jano/Developer/code/janodev/simlease/Sources/SimLeaseCore/FileLock.swift`
- `/Users/jano/Developer/code/janodev/simlease/Sources/simlease/SimleaseCLI.swift`
- `/Users/jano/Developer/code/janodev/simlease/Sources/simlease/MacOSUICommand.swift`
- `/Users/jano/Developer/code/janodev/simlease/Tests/SimLeaseCoreTests/FileLockTests.swift`

SimLease already demonstrates persistent Darwin `flock` files, monotonic wait
deadlines, explicit descriptor inheritance, supervised signal forwarding, and
direct `exec` for a host-wide UI gate. Reuse learned invariants, but do not make
AgentLease import SimLease or take responsibility for simulator creation.

Do not copy SimLease's current `FileLock.release()` implementation: it explicitly
calls `LOCK_UN`. AgentLease must close without unlocking so inheriting children
and descendants retain ownership after the coordinator releases its reference.

Notika's current build coordinator is another requirements source:

- `/Users/jano/Developer/code/janodev/Notika/Scripts/notika_dev.py`
- `/Users/jano/Developer/code/janodev/Notika/Makefile`

Study it for generated-project and DerivedData resource boundaries, command
provenance, cancellation, and artifact handling. Do not begin by porting that
large script line for line. Implement the small generic lock-and-command
contract above, then integrate it with one opt-in Notika Make target as a later,
separately authorized migration experiment.
