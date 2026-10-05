gen:
	./scripts/xcodegen generate

build-ios: gen
	xcodebuild -project PocketSand.xcodeproj -scheme PocketSand-iOS \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

build-macos: gen
	xcodebuild -project PocketSand.xcodeproj -scheme PocketSand-macOS \
		-destination 'platform=macOS' build

test:
	swift test --package-path Packages/KandevKit

# Filters name the suite *type*, not its display name: --filter matches on
# `LiveServerTests`, and a pattern like "Live server" silently matches nothing,
# which looks exactly like a passing run.
test-live:
	KANDEV_LIVE=$(KANDEV) swift test --package-path Packages/KandevKit --filter LiveServerTests

# Starts an agent, so it needs a scratch task that already has a session running.
# The environment is set on each command. On a single line it would reach only the
# first, and the second suite would be skipped while reporting no failures; as a
# target-level export it did not reach either, and the suite crashed instead.
test-live-write:
	KANDEV_LIVE=$(KANDEV) KANDEV_LIVE_WRITE=$(TASK) KANDEV_LIVE_PROFILE=$(PROFILE) \
		swift test --package-path Packages/KandevKit --filter LiveComposerTests
	KANDEV_LIVE=$(KANDEV) KANDEV_LIVE_WRITE=$(TASK) KANDEV_LIVE_PROFILE=$(PROFILE) \
		swift test --package-path Packages/KandevKit --filter LiveFollowTests

# Your own server, kept out of the repository: copy local.mk.example to local.mk
# and put the address there. The default below is a placeholder, so the live
# targets do nothing useful until you do.
-include local.mk
KANDEV ?= http://kandev.local:38429

probe:
	swift run --package-path Packages/KandevKit kandev-probe $(KANDEV)

probe-v1:
	swift run --package-path Packages/KandevKit kandev-probe $(KANDEV) < Packages/KandevKit/Probe/discovery.json

.PHONY: gen build-ios build-macos test test-live test-live-write probe probe-v1
