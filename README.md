# AgentLease

AgentLease is a macOS command-line tool for running cooperating agent workflows
while holding exclusive, named local resources. Darwin `flock` ownership is the
authority; JSON records provide diagnostics only.

The project is under active implementation. The version-one contract and build
plan are in [Docs/IMPLEMENTATION_BRIEF.md](Docs/IMPLEMENTATION_BRIEF.md).

## Requirements

- macOS 27 or later
- Xcode 27 or later
- Swift 6.4

## Development

```sh
make build
make test
```

The package pins Swift Subprocess to the released 1.0.x line. Supervised
execution will use null stdin and inherited stdout/stderr. Direct `exec` mode
will preserve interactive standard streams. Both modes intentionally pass owned
lock descriptors to the command, so an inheriting descendant can retain a lock
after its coordinator exits. A stale JSON record never grants ownership and
never makes a kernel lock free.
