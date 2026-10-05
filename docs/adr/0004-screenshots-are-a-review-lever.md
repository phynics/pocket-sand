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

## Update: the screens are read, not diffed

`scripts/visual-check` turns the captures into a check, and it does it by **reading the
text on them** with Vision rather than comparing pixels. Three rules, and the first two
need no expectations to be written:

- **Nothing was cut to fit.** An ellipsis on a line means a word did not fit. A few are
  deliberate and are named in `scripts/visual-expectations.json` under
  `_expectedTruncation` — the connect screen's `kandev_pat_…` placeholder is one.
- **No word was broken in half.** A line ending in a hyphen is the layout admitting it
  had nowhere to put the word: "Set-" above "up".
- **The screen says what it is supposed to say**, per key. Expectations are keyed by
  *capture* rather than by screen — `newtask@accessibility-extra-extra-large` — because
  what is on screen at the largest text size is not what is on screen at the default
  one, and an anchored capture has no entry at all: a region gets the two whole-screen
  rules and nothing else, since it is for looking at rather than for asserting against.

This is better than diffing images for the reason the alternative was deferred: a system
font update or a different simulator runtime moves every pixel and means nothing, while
an ellipsis that was not there yesterday means something. It is also what makes the
check worth having on a screen nobody has looked at.

It caught four of the five defects that prompted it, and one nobody had noticed: the
setup screen's example placeholder was longer than its field, at the *default* text size.

**What it does not do.** It only sees what is on screen, so a defect below the fold is
invisible to it unless the run scrolls there with `SCROLL`. It needs a server for any
screen with data, which keeps it off CI until fixtures exist — the same alternative
deferred above, now with a concrete reason to build it. And it is a set of heuristics:
"a line ending in a hyphen" is a good proxy for a broken word, not a proof of one.

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
