# 4. Screenshots are a review lever, not a test

Date: 2026-10-05

## Status

Accepted

## Context

Every visual defect found in this app so far was found by looking at it: a card that
should not have been there, a placeholder that read as a heading, a picker rendering
one row's answer in grey while the row above it was ink, a keyboard hiding the second
door. None of them would have been caught by the tests, which cover the model layer
only ([ADR-0003](0003-tests-cover-the-model-layer.md)), and none of them were caught
by reading code.

Looking at it, though, was done by hand: patch `TaskListView` to open a screen, build,
`sleep 15`, screenshot, patch it back. That ritual has two costs. It is slow, and it
is unsafe — a backup taken while the patch was live restores the patch, which is how a
hardcoded task id nearly shipped.

There is no way to drive the simulator instead: no `idb` on this machine, no touch
command in `simctl`, and the Testing framework refuses to compile inside a UI-test
bundle, so UI automation is not merely discouraged here but unavailable.

## Decision

Visual validation is a **script plus a debug-only screen override**, not a test.

- `Apps/PocketSand/ScreenshotTour.swift` opens a screen named in the environment. It
  is inert in a release build, so it cannot be reached by a shipped app.
- `scripts/screenshots` walks screens × appearances × text sizes, waits for a
  readiness file each screen writes, freezes the status bar, and writes a contact
  sheet. It exits non-zero when a screen settles empty or failed, because a picture of
  a screen that could not load is not evidence about how that screen looks.
- The images land in `artifacts/`, which is gitignored. They are artifacts, not
  fixtures.

## Alternatives considered

- **UI tests** — impossible here, not merely unattractive: the test framework does not
  compile in a UI-test bundle on this toolchain, and there is no tap command to drive
  the simulator with in any case.
- **Commit golden images and diff them in CI.** Deferred rather than rejected. It is
  the natural next step, and it is worth doing after the review flow has been used
  enough to know which screens change often: a golden set that fails on every system
  font bump is a set people learn to ignore.
- **Fixtures so screens render without a server.** Rejected for now. The protocol
  seams exist (`KandevTaskSource`, `KandevConversationServer`) and a fixture source is
  a small piece of work, but the states worth photographing are the ones the server
  produces — and a fixture is a second implementation of the server that will drift.
- **Keep patching a view by hand.** Rejected: it is the ritual this replaces, and its
  failure mode is shipping a hardcoded id.

## Consequences

- Debug-only code lives in the app: a screen override, and a readiness call in each
  screen. It costs a no-op in release and a line in three views.
- A run needs a server for screens with data, which makes it machine-specific until
  fixtures exist.
- Nothing interactive is covered. Menus, a half-typed field and a swipe are still
  checked by hand, on a device, by a person.
- The images are not compared by anything. This makes "did appearance change?" a
  question for a person or an agent looking at the contact sheet, which is the point:
  it is a lever for review, not a gate.
