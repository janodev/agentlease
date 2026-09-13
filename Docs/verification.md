---
type: Verification
title: Version 1 verification map
description: Maps each required version-one scenario to its primary automated regression coverage.
tags: [agentlease, testing, verification]
timestamp: 2026-09-14T00:00:00+02:00
status: implemented
---

# Test strategy

Swift Testing suites combine focused core checks with real subprocesses and
isolated `AGENTLEASE_HOME` roots. Marker files and monotonic deadlines establish
lifecycle barriers; fixed sleeps are not used as the primary synchronization
mechanism. The root `make test` target builds the package and runs every suite.

# Required-scenario map

| Scenario | Primary coverage |
| ---: | --- |
| 1 | `LeaseSetTests.contentionAndIndependence` |
| 2 | `LeaseSetTests.contentionAndIndependence` |
| 3 | `LeaseSetTests.sortedMultiLockOrder` |
| 4 | `LeaseSetTests.partialAcquisitionCleanup`, `positiveDeadlineCoversSet` |
| 5 | `RunCommandTests.argumentsRecordsAndOutput`, `ExecCommandTests.streamsEnvironmentAndRecord` |
| 6 | `RunCommandTests.signalTeardown` |
| 7 | `RunCommandTests.signalTeardown`, `SupervisedSubprocessTests.cancellationReapsProcessGroup` |
| 8 | `RunCommandTests.supervisorDeathRetention`, `SupervisedSubprocessTests.inheritedLockSurvivesCoordinatorSIGKILL` |
| 9 | `ExecCommandTests.streamsEnvironmentAndRecord`, `signalAndCrashRelease` |
| 10 | `ExecCommandTests.descendantRetention` |
| 11 | `RunCommandTests.nestedInvocation`, `StatusCommandTests.heldFreeAndNested` |
| 12 | `AgentLeasePathsTests.rejectsUnsafePaths`, `FileLockTests.rejectsUnsafeLockFiles`, `StatusProbeTests.unexpectedEntries` |
| 13 | `RunCommandTests.staleRecordDoesNotBlock` |
| 14 | `StatusProbeTests.heldAndFree`, `StatusCommandTests.heldFreeAndNested` |
| 15 | `ExecutionPolicyTests.argumentCommitment`, run and exec exact-argument tests |
| 16 | `RunCommandTests.argumentPrivacyAndNullInput`, `ExecCommandTests.streamsEnvironmentAndRecord` |
| 17 | Run and exec `signalDuringAcquisition` tests |
| 18 | Shared path-policy tests plus run and exec executable-format tests |
| 19 | Run and exec preflight tests plus publication-precedence tests |
| 20 | `FileLockTests.descriptorPolicyAndExplicitRelease`, supervised inheritance tests, and `ExecCommandTests.signalAndCrashRelease` |
| 21 | `RunCommandTests.signalTeardown` |
| 22 | Shared executable-preflight tests plus run and exec launch-error tests |
| 23 | `LeaseSetTests.deadlineEdges`, `positiveDeadlineCoversSet`, and `RunCommandTests.timeoutCleanup` |
| 24 | `AgentLeasePathsTests` safe-layout, symlink, concurrent-creation, and restrictive-umask tests |
| 25 | Run child-environment and exec streams/environment tests |
| 26 | `RunCommandTests.runningPublicationFailure`, `terminalPublicationPrecedence` |
| 27 | `AgentLeasePathsTests.stateRootSelection`, unsafe-path tests, and `RunCommandTests.invalidInputBeforeState` |
| 28 | `StatusProbeTests` and `StatusCommandTests.unexpectedEntries` |
| 29 | `LeaseSetTests.metadataFailureIsBestEffort` and runner terminal-order tests |

# Platform evidence

The integration suite runs against Swift 6.4 and the macOS 27 SDK. Swift
Subprocess behavior that affects session creation, descriptor inheritance,
signal defaults, process-group escalation, and reaping remains covered by the
dedicated spike suite described in
[Swift Subprocess integration](subprocess-integration.md).
