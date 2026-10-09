.PHONY: build test

SWIFT_JOBS ?= 2

build:
	swift build --jobs $(SWIFT_JOBS)

test: build
	swift test --jobs $(SWIFT_JOBS)
