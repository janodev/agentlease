.PHONY: build test

build:
	swift build

test: build
	swift test
