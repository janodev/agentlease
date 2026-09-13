# AgentLease

AgentLease coordinates local agent workflows with exclusive named resources.
Darwin `flock` ownership is authoritative; JSON records and lock metadata are
diagnostic only. It is a standalone tool and does not depend on Beads, SimLease,
Notika, or an Xcode project.

## Requirements

- macOS 27 or later
- Xcode 27 or later
- Swift 6.4

The Swift package declares `// swift-tools-version: 6.4` and `.macOS(.v27)`.

## Install

Build a release binary and copy it to a directory on `PATH`:

```sh
swift build -c release
install -m 755 .build/release/agentlease "$HOME/.local/bin/agentlease"
```

The destination directory must already exist. A packaged release can install
the same built `agentlease` executable; no runtime service or daemon is needed.

## Use

A resource name matches `[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}`. Supply between one
and 64 distinct resources. AgentLease sorts the complete set before acquisition,
so callers may list resources in any order without introducing lock-order
deadlocks.

Supervise a noninteractive command:

```sh
agentlease run \
  --resource notika:xcode-project-generation \
  --resource notika:derived-data:debug \
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
--resource <name>       Repeatable and required.
--label <text>          Optional 1...256-byte diagnostic label.
--bead <id>             Optional 1...256-byte correlation value.
--wait-seconds <value>  Finite nonnegative acquisition deadline; wait forever if absent.
--record-arguments      Persist the full argv; otherwise store only its commitment.
-- <executable> [args]  Required direct argument boundary; no implicit shell.
```

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
close them or configure their own spawn actions otherwise.

This inheritance is intentional crash safety. If a `run` coordinator receives
`SIGKILL`, a surviving child still prevents another owner from entering, while
the JSON record may remain `running`. A background descendant can similarly
retain a lock after its direct parent exits. Diagnose that case with `lsof` on
the persistent lock file and terminate the workload that owns its descriptor.
Never delete a lock file: deletion cannot revoke the old inode lock and can
split ownership between two inodes.

Child commands are cooperative. A command that deliberately closes or unlocks
unknown inherited descriptors can defeat retention.

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
