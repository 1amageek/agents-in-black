SWIFT = /usr/bin/swift
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) --show-bin-path)
BUILD_CONFIGURATION ?= debug
ENTITLEMENTS = signing/aib-cli.entitlements

.PHONY: all build release debug clean sign test

all: build sign

build:
	$(SWIFT) build -c $(BUILD_CONFIGURATION)

release: BUILD_CONFIGURATION = release
release: all

debug: BUILD_CONFIGURATION = debug
debug: all

sign:
	@echo "Signing CLI binaries with virtualization entitlement..."
	codesign --force --sign - --timestamp=none --entitlements=$(ENTITLEMENTS) "$(BUILD_BIN_DIR)/aib-dev"

test:
	$(SWIFT) test --timeout 30

clean:
	$(SWIFT) package clean
