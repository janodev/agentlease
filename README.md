# AgentLease

Run multiple coding agents on one Mac with less resource contention, lighter
simulators, and less disk clutter. Competing builds and desktop UI tests take
turns while independent work continues in parallel.

This project is part of a set of tools:
- [AgentBuild](https://github.com/janodev/agentbuild) coordinates builds and tests, reuses caches, and records results.
- [AgentLease](https://github.com/janodev/agentlease) coordinates access to shared resources, reducing contention and preventing conflicting work.
- [SimLease](https://github.com/janodev/simlease) provides disposable simulators, cleans them up afterward, and queues macOS UI automation.
- [SimSlim](https://github.com/janodev/simslim) disables unneeded Simulator background services to reduce memory use.

AgentLease, SimLease, and SimSlim work independently. AgentBuild is a build driver that runs supported project workflows and coordinates the other tools as needed.

## Why AgentLease?

Examples:

- **Competing for CPU.** Compilation can saturate the CPU, so queueing builds reduces contention. AgentBuild uses an exclusive AgentLease `host:compile` lease to do this.
- **Queueing exclusive resources.** UI automation requires exclusive access to the desktop to prevent agents from interfering with each other's clicks and keyboard focus.

### What's wrong with using a lock file?

AgentLease uses lock files too, with ownership enforced by the operating system.
A plain `lock.md` recording "free" or "taken" leaves these problems to the agents:

- **Races.** Two agents can read "free" before either writes "taken". AgentLease uses `flock` to make acquisition atomic.
- **Stale claims.** A crashed agent can leave "taken" behind. Kernel ownership ends when the last holding file descriptor closes, including after a crash.
- **Surviving work.** An agent can die while its build keeps running. Inherited lock descriptors let child processes retain ownership while they continue working.

Resources are names you choose, such as `myapp:build-output`. Shared leases let
agents read the same build artifacts concurrently; exclusive leases reserve them
for rebuilding or deletion. AgentLease waits for busy resources and acquires
multiple resources in a consistent order to avoid lock-order deadlocks. All
participants must use the same resource names and state root.

## Requirements

- macOS 27 or later
- Xcode 27 or later
- Swift 6.4

The Swift package declares `// swift-tools-version: 6.4` and `.macOS(.v27)`.

## Install

Just ask your coding agent to install AgentLease from this repository. It can
handle the steps below for you.

Build a release binary and copy it to a directory on `PATH`:

```sh
swift build -c release
install -d "$HOME/Developer/tools"
install -m 755 .build/release/agentlease "$HOME/Developer/tools/agentlease"
```

Add `~/Developer/tools` to `PATH`. A packaged release can install
the same built `agentlease` executable; no runtime service or daemon is needed.
This contract reports `agentlease --version` as `2.1.0`. Run-record and status
JSON retain schema version 2, and the inherited descriptor manifest retains
schema version 1. Version 2.1 adds coordinated retention.

## Use

A resource name matches `[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}`. Supply between one
and 64 distinct resources across `--resource` and `--shared-resource`.
`--resource` is exclusive and preserves the version-1 behavior;
`--shared-resource` can overlap other shared holders of the same name but waits
for an exclusive holder. A name may appear only once across both modes.
AgentLease sorts the complete mixed-mode set before acquisition, so callers may
list resources in any order without introducing lock-order deadlocks.

Supervise a noninteractive command:

```sh
agentlease run \
  --resource notika:xcode-project-generation \
  --shared-resource notika:derived-data:debug \
  --label "Debug build" \
  -- make build-macos
```

`run` gives the child `/dev/null` stdin and inherits the caller's stdout and
stderr. It creates a child session, relays `SIGINT`, `SIGTERM`, and `SIGHUP`,
applies process-group escalation, waits for reaping, records the outcome, and
then releases the coordinator's lock descriptors. Use `exec` when the command
must read an interactive terminal:

```sh
agentlease exec --resource example:interactive-shell -- zsh
```

`exec` replaces AgentLease in place, preserving stdin, stdout, stderr, the
terminal process group, exact arguments, exit status, and ordinary signal
behavior. Its record remains `handoffPrepared`, because no coordinator survives
successful replacement to observe a terminal outcome.

Inspect kernel ownership and diagnostic metadata:

```sh
agentlease status
agentlease status --json
```

Held resources are a successful status result. Unexpected or unsafe lock
directory entries are still reported and make `status` return 70. A free entry
may show a historical last owner; stale metadata never makes a lock held or
free.

Common options for `run` and `exec` are:

```text
--resource <name>        Repeatable exclusive resource.
--shared-resource <name> Repeatable shared resource.
--label <text>          Optional 1...256-byte diagnostic label.
--bead <id>             Optional 1...256-byte correlation value.
--wait-seconds <value>  Finite nonnegative acquisition deadline; wait forever if absent.
--record-arguments      Persist the full argv; otherwise store only its commitment.
-- <executable> [args]  Required direct argument boundary; no implicit shell.
```

At least one resource option is required. The 64-resource and 4,096-byte
comma-separated name limits apply to the combined set.

For a shell pipeline, request the shell explicitly:

```sh
agentlease run --resource example:build -- zsh -lc 'make build && make test'
```

For Beads-oriented work, pass an existing Bead ID only as correlation metadata:

```sh
agentlease run \
  --resource notika:tests:region-selection \
  --bead notika-62i.1.12.1.2.1 \
  -- make test-unit
```

AgentLease never opens or changes a Beads database.

## Ownership and recovery

The default state root is `.agentlease` under the effective user's account-home
directory; it is not derived from the mutable `HOME` environment variable.
`AGENTLEASE_HOME` selects an explicit absolute root, primarily for isolated
workflows and tests.

Owned lock descriptors are duplicated at descriptor 64 or above. Supervised
mode keeps them close-on-exec in the coordinator and selects them explicitly for
child inheritance. Direct mode clears close-on-exec only immediately before
replacement. Descendants inherit these descriptors unless they deliberately
close them or configure their own spawn actions otherwise. Each immediate child
also receives `AGENTLEASE_LEASE_DESCRIPTORS`, a compact deterministic JSON
manifest:

```json
{"leases":[{"descriptor":64,"mode":"shared","path":"/absolute/state/locks/<sha256>.lock","resource":"example:cache"}],"schemaVersion":1}
```

The `leases` array uses the same resource-name order as acquisition. Each entry
contains the exact inherited descriptor number, `shared` or `exclusive` mode,
validated resource name, and persistent canonical lock path. The encoded UTF-8
value is limited to 131,072 bytes; each absolute path is limited to 4,096 bytes
and may not contain C0 or C1 control scalars. AgentLease removes any inherited
value before acquisition and overwrites it with the current manifest after the
complete set is owned. `AGENTLEASE_HELD_RESOURCES` remains the nested-execution
guard and contains the same sorted names without mode information.

This inheritance is intentional crash safety. If a `run` coordinator receives
`SIGKILL`, a surviving child still prevents another owner from entering, while
the JSON record may remain `running`. A background descendant can similarly
retain a lock after its direct parent exits. Diagnose that case with `lsof` on
the persistent lock file and terminate the workload that owns its descriptor.
Manually unlinking a held lock cannot revoke the old inode lock and can split
ownership between two inodes. Use coordinated cleanup to retire idle files.

Child commands are cooperative. A command that deliberately closes or unlocks
unknown inherited descriptors can defeat retention.

Trusted integrations that must establish one inherited exclusive lease before
entering a protected child may invoke the hidden
`verify-inherited-exclusive --resource <name>` command with the inherited
descriptor manifest. It validates the exact single-resource envelope and safe
inode, then establishes the exclusive flock on the same open-file description.
This does not authenticate the original coordinator.

Shared holders do not rewrite the common lock file's last-owner metadata,
because concurrent truncate-and-write operations would race. Run records and
the inherited manifest retain every requested mode. `status` derives both
availability and a held mode from kernel lock probes; metadata remains only
historical diagnostics.

## Coordinated retention

Preview old idle resource locks and run history, then execute the same policy:

```sh
agentlease cleanup --json
agentlease cleanup --execute --json
```

The default age is seven days. `--older-than-days <value>` accepts a finite
nonnegative age. Repeat `--keep-lock-digest <sha256>`,
`--keep-lock-path <canonical-path>`, and `--keep-run-id <uuid>` to preserve
descriptor handoffs, replay evidence, or selected diagnostics. At most 1,024
protections are accepted. A lock protection preserves that inode; use a run-ID
protection when its historical JSON must also remain.

The permanent root `.registry.lock` coordinates acquisition, status, record
publication, inherited verification, and cleanup. Cleanup skips a busy registry
immediately. It removes an old resource file only after taking an independent
exclusive flock and confirming the safe pathname still names that inode.
Old run records remain whenever any referenced resource is held or unsafe,
including leases retained by descendants after the coordinator exits. This
conservative rule can retain history beyond seven days while resources remain
in use. Recent completion or file modification also preserves a record.

Before executing cleanup in an existing state root, ensure every process that
can acquire or re-establish ownership uses AgentLease 2.1 coordination and no
older acquisition is in flight. Existing held applications can remain open;
their kernel locks protect their resource files. Preserve idle descriptor or
replay references explicitly with the keep options.

Automatic cleanup is disabled unless an integration sets
`AGENTLEASE_AUTO_CLEANUP=1`. It runs before `run` or `exec` acquisition, at most
once per 24 hours per state root when the registry is available. Integrations
can additionally set `AGENTLEASE_CLEANUP_KEEP_LOCK_DIGESTS` to a comma-separated
list of lowercase 64-character SHA-256 digests, limited to 1,024 entries and
131,072 UTF-8 bytes. Automatic cleanup diagnostics preserve the command's normal
result. `status` stays read-only. See [retention](Docs/retention.md) for the
coordination and rollout contract.

## Exit behavior

| Result | Exit code |
| --- | ---: |
| Child normal exit | Child status |
| Child or relayed signal | `128 + signal` for `run`; native signal death for `exec` |
| Command not found | 127 |
| Command not executable | 126 |
| Usage error | 64 |
| Acquisition timeout | 75 |
| AgentLease setup or required publication failure | 70 |

A terminal-record failure preserves a nonzero child result; it changes an
otherwise successful supervised result to 70. Lock metadata writes are
best-effort and never change command execution or exit status.

## Development and documentation

```sh
make build
make test
```

CI requires a self-hosted Apple-silicon runner with macOS 27 and Xcode 27 and
checks the Swift 6.4 toolchain before running those Makefile targets. The
authoritative behavior and implementation rationale are indexed in
[Docs/index.md](Docs/index.md).

## License

MIT — see [LICENSE](LICENSE).
