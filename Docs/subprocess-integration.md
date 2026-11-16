# Scope

AgentLease uses Swift Subprocess 1.0.0 for supervised execution. The package is
compiled with Swift 6.4 from Xcode 27 and targets macOS 27 or later. The resolved
version is checked into `Package.resolved`.

The integration tests exercise real child processes rather than substituting a
process protocol. Their helper is the `agentlease-spike-helper` package product.

# Verified behavior

The spike verifies these behaviors against the selected dependency:

1. `input: .none` gives the child `/dev/null` stdin, while
   `.currentStandardOutput` and `.currentStandardError` inherit the coordinator's
   output descriptors.
2. The running-process closure exposes the child PID, and the completed result
   exposes its normal or signal termination.
3. `Arguments(executablePathOverride:remainingValues:)` preserves the caller's
   selected `argv[0]` independently from the resolved executable path.
4. Swift Subprocess resets child signal dispositions to defaults.
5. In the fixture where both the leader and grandchild ignore initial signals,
   cancellation runs the two-second process-group interrupt step, the five-second
   process-group termination step, and the implicit final process-group kill.
   The direct child is reaped before the operation returns, and the grandchild
   is removed with the group. This does not prove later escalation when the
   leader exits after an earlier signal; see the immediate policy below.
6. A descriptor retained with `F_DUPFD_CLOEXEC` remains close-on-exec in the
   coordinator. `posix_spawn_file_actions_addinherit_np` makes it available with
   close-on-exec cleared in the child.
7. Killing the coordinator with `SIGKILL` leaves the inherited `flock` held by
   the surviving child. A separate waiter acquires it only after that child dies.

Byte-streaming output remains separate from raw-file redirection. The AgentLease
CLI inherits ordinary child output rather than capturing it.

# Core output redirection

`SupervisedSubprocess.run` accepts an optional `workingDirectory` and optional
`standardOutputDescriptor` / `standardErrorDescriptor`. Existing callers keep
their current directory and inherited standard streams when these arguments
are omitted. Working-directory selection uses the dependency's checked Darwin
`posix_spawn_file_actions_addchdir_np` path and retains the session and selected
lease-descriptor configuration below.

The caller owns redirected descriptors and keeps them open until the awaited
operation completes, including failure and cancellation teardown. Subprocess
duplicates each chosen descriptor onto its child standard stream with
`closeAfterSpawningProcess: false`; the caller's descriptor stays open and its
close-on-exec flag stays unchanged. The Core does not open, validate, flush, or
close caller log files.

Redirecting to regular files preserves arbitrary bytes without a capture-size
limit or a pipe read waiting for descendant EOF. Normal and signal termination
retain the same result policy. Descendants can retain their inherited standard
streams after the direct child finishes, so logs may continue changing; the
result describes the direct child rather than finality of all output or
descendant termination. Disk write failure is observed by the writing child,
not automatically converted into a Core capture error.

`SupervisedLoggingTests` exercises exact arguments and working directory,
separate large binary logs, native nonzero and signal results, retained caller
descriptors after success and callback failure, and lock retention by a
descendant after the direct child exits with redirection enabled.

A dependency error explicitly identifying a failed working-directory change
is classified as setup failure (`spawn`, operation `changeWorkingDirectory`,
exit 70), even when its errno is `ENOENT`. It must not be reported as a missing
executable (exit 127). The missing-directory fixture verifies that no start
callback runs and caller-owned output descriptors remain open.

The Core also accepts an optional `teardownSequence`; omission retains the
AgentLease CLI's graceful defaults. Callers that require immediate cancellation
may select a first step sending `.kill` to the process group. This addresses
Subprocess 1.0 stopping further escalation once the direct child exits: a gentle
first signal can terminate that leader before an ignoring descendant receives
a later step. The immediate policy targets a still-live leader's entire group
at the first step, and `SupervisedLoggingTests.immediateGroupCancellation`
checks direct-child reaping and disappearance of its signal-ignoring descendant.
It does not reach descendants that have already left that group, or guarantee
group cleanup if the leader exited before cancellation.

# Session configuration

Swift Subprocess 1.0.0 takes a pre-fork implementation path when
`PlatformOptions.createSession` is true. In that path, spawning with an inherited
descriptor that remains `FD_CLOEXEC` in the coordinator fails with `EBADF`, even
when the Darwin file actions contain an inheritance operation.

AgentLease therefore leaves `createSession` false. Its Darwin
`preSpawnProcessConfigurator` preserves the dependency's existing attribute
flags, adds `POSIX_SPAWN_SETSID`, and adds one checked
`posix_spawn_file_actions_addinherit_np` operation for each owned descriptor.
It also checks that `SIGINT`, `SIGTERM`, and `SIGHUP` are present in the spawn
default set and absent from the spawn mask, rather than relying only on the
dependency's unchecked setup calls.
This uses the direct `posix_spawn` path and creates a new session atomically
without widening descriptor inheritance in the coordinator.

# Regression boundary

Do not change session creation back to `PlatformOptions.createSession` unless a
compiled integration test demonstrates that the selected Swift Subprocess
version accepts close-on-exec inherited descriptors on that path. Keep the
coordinator `FD_CLOEXEC` assertion, process-group cancellation test, and
coordinator-`SIGKILL` retention test together: all three are required to prove
the ownership contract.
