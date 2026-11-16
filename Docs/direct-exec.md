# Replacement contract

`agentlease exec` shares resource validation, executable resolution, argument
commitment, child-environment construction, ordered acquisition, and record
publication with supervised mode. It preserves the caller's stdin, stdout,
stderr, process group, exact argument array, and inherited environment except
for AgentLease's reserved correlation fields.

After publishing `acquired`, direct mode exports the exact sorted shared and
exclusive descriptor manifest and deliberately clears `FD_CLOEXEC` only on the
retained lock descriptors. It then publishes `handoffPrepared`, writes matching
best-effort metadata for exclusive locks, and calls Darwin `execve` with the
already resolved path. Shared locks do not mutate common metadata. Direct mode
never calls `execvp` and never interprets an executable-format failure through
a shell.

Successful replacement retains the AgentLease PID and leaves the run record at
`handoffPrepared`; there is no surviving coordinator that could truthfully
publish a terminal outcome. Kernel descriptor closure releases ownership when
the replacement and every inheriting descendant have closed their copies.

# Signal-mask invariant

Signal dispositions are not replaced by an AgentLease relay in direct mode.
AgentLease snapshots the inherited thread signal mask at process entry and
restores that exact mask on the thread that invokes `execve`. This matters
because an async Swift task may resume on a runtime worker with a different
thread-local mask. Without the snapshot, the replacement could unexpectedly
inherit the worker's blocked signals instead of the caller's launch state.

A signal during acquisition therefore has ordinary process behavior: the
kernel closes partial ownership and any acquiring record can remain stale. A
signal or `SIGKILL` after replacement terminates the command directly and
releases its locks unless another inheriting descendant remains alive.

# Failure behavior

If descriptor preparation or `handoffPrepared` publication fails, no command is
started. If `execve` returns, AgentLease publishes `failed`, attempts matching
best-effort metadata for exclusive locks, reports the error, and closes all retained
descriptors without an explicit unlock. Missing interpreters map to 127;
permission and executable-format failures map to 126; AgentLease setup and
publication failures map to 70. Failure-record publication is attempted once,
and its own failure forces 70 because no child started.

Production executable tests cover exact `argv[0]`, interactive streams,
reserved environment fields, multiple inherited lock descriptors, normal and
signal exit, `SIGKILL`, descendant retention, acquisition-time signals,
launch-time 126/127 mapping, and publication failure before replacement.
