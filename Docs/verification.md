---
type: Verification
title: AgentLease verification map
description: Maps the original scenarios and AgentLease 2 shared-resource contracts to automated regression coverage.
tags: [agentlease, testing, verification]
timestamp: 2026-09-14T00:00:00+02:00
status: implemented
---

# Test strategy

Swift Testing suites combine focused core checks with real subprocesses and
isolated `AGENTLEASE_HOME` roots. Marker files and monotonic deadlines establish
lifecycle barriers; fixed sleeps are not used as the primary synchronization
mechanism. The root `make test` target builds the package and runs every suite.

# Original required-scenario map

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

# AgentLease 2 regression map

| Contract | Primary coverage |
| --- | --- |
| Shared holders coexist and exclude exclusive holders | `FileLockTests.sharedAndExclusiveCompatibility`, `RunCommandTests.sharedResourceCompatibility` |
| Mixed modes use one sorted set and reject all duplicates | `ResourceNameTests.mixedLeaseModes`, `rejectsInvalidValues`, `RunCommandTests.rejectsCrossModeDuplicate` |
| Shared holders never race on common metadata | `LeaseSetTests.sharedMetadataIsReadOnly` |
| Status derives shared/exclusive mode from `flock` and handles release between probes | `StatusProbeTests.sharedModeAndReleaseRace`, `RunCommandTests.sharedResourceCompatibility` |
| Manifest encoding is deterministic, bounded, sorted, and rejects unsafe fields | `ExecutionPolicyTests.inheritedLeaseManifest` |
| Real `run` and `exec` children receive exact open descriptors, modes, and persistent paths | Run and exec `leaseDescriptorManifest` tests plus the helper's `verify-lease-manifest` command |
| A cooperating child can establish one validated inherited exclusive lease without a second lock namespace | `InheritedExclusiveLeaseGuardTests` mode, inode, and live contention checks |
| Stale manifest values are removed and overwritten | `ExecutionPolicyTests.childEnvironment` and both CLI manifest tests |
| Run records retain each resource mode in schema 2 | Run and exec `leaseDescriptorManifest` tests |
| Mixed shared/exclusive descriptors survive coordinator death through the child and retain exact compatibility | `RunCommandTests.mixedModeSupervisorDeathRetention` |

# Platform evidence

The integration suite runs against Swift 6.4 and the macOS 27 SDK. Swift
Subprocess behavior that affects session creation, descriptor inheritance,
signal defaults, process-group escalation, and reaping remains covered by the
dedicated spike suite described in
[Swift Subprocess integration](subprocess-integration.md).
