# Tests cover the model layer, not the views

UI automation is unavailable to Swift Testing: `XCUIApplication` lives in XCTest,
and the Testing framework refuses to compile in a UI-testing bundle at all
(`Unable to resolve module dependency: '_Testing_Unavailable'`). Rather than keep
a second test framework alive for one target, tests cover the model layer —
wire types, transports, and the observable stores the views bind to — and
appearance is verified by hand.

## Considered Options

- **An XCTest UI target.** Rejected for now: it means two frameworks, two
  assertion styles, and a target whose tests only pass with a live server.
- **Rendering views in-process with `ImageRenderer`.** Tried and removed. It
  works, but it tests views, which is what the model-layer rule excludes. Two
  things were learned first and are worth keeping: a blank render passes a size
  assertion (`ScrollView` measures as empty offscreen), and `ProgressView` does
  not draw offscreen at all.

## Consequences

Anything worth testing has to live in a model, so logic moves out of views by
pressure rather than by good intentions. Two examples: `ConnectView` no longer
decides what a valid server address is — `ServerAddress` does — and the
Keychain sits behind `TokenStorage` so the store can be tested without a
keychain prompt blocking a test run.

The cost is real and accepted: nothing automated checks that a row looks right,
that a tap navigates, or that a screen scrolls. Those are manual checks, and a
green suite is not evidence about them.
