# Working in this repo

## Boundaries

`Packages/KandevKit` holds the wire types, the transport, and the state. It does
not import SwiftUI. The app targets in `Apps/PocketSand` render state and call
into `KandevKit`; **views never touch the socket.** If a view needs new data, it
asks the store, and the store asks the client.

## Naming

- The primary object is a **Task** in prose, in UI copy, and in filenames. In
  Swift it is `KandevTask`, because `Task` is the concurrency primitive.
- Every type that mirrors something on the wire carries the `Kandev` prefix:
  `KandevEnvelope`, `KandevSession`, `KandevErrorPayload`. Types that exist only
  in this app do not.
- Follow `CONTEXT.md`. If code and glossary disagree, one of them is a bug.

## The protocol is pinned, not tracked

`KandevProtocol` targets one Kandev release line (`KandevWireVersion.releaseLine`).
Kandev calls `/ws` an internal protocol that can change without notice, so:

- Every wire type and action carries a doc comment naming the server version and
  the action it was verified against.
- Upstream's `/ws` reference is vendored at
  `docs/reference/kandev-websocket-api.md`. It documents an older,
  board-and-column surface, so trust its envelope and its `error` frame, not its
  action names.
- Changing the pin is a deliberate commit that updates types, tests, and the
  constant together — never a silent drift.

## Talking to a server

Point the app at a Kandev server of your own. The one this was built against ran
on port 38429 over **plain HTTP**, which App Transport Security blocks, so both
`Info.plist` files set `NSAllowsArbitraryLoads`. A per-domain exception would
have had to name somebody's server in a public repository, and the app only ever
talks to an address that someone typed in themselves.

The live test suites take their address from a gitignored `local.mk` at the repo
root — copy `local.mk.example` and set `KANDEV`. The default in the `Makefile` is
a placeholder, so a fresh clone cannot reach anybody's server by accident, and the
address of a private one never enters the repository.

Writes against a real server are read-only by default: use a scratch workspace,
and ask before anything starts an agent.

## Unused code

Two kinds of thing live here, and the rule differs:

- **Spec tables may hold verified-but-unused entries.** `KandevAction` and
  `KandevHTTPRoute` are the written-down protocol, so an action nobody calls yet
  still belongs if a live server confirmed it. That is the point of them.
- **Everything else must be used.** A field on a view model, a helper, or a
  constant that nothing reads is dead weight; delete it or wire it up. `TaskRow`
  lost its `state` field this way, and `KandevWorkspace`'s scope helpers sat
  unused until the composer was made to respect them.

## Verification

Tests cover the model layer only — wire types, transports, and the observable
stores. There are no view tests and no UI automation, for the reason recorded in
`docs/adr/0003`. Anything worth testing has to live in a model, so put the logic
in one: `ServerAddress` exists because `ConnectView` was deciding what a valid
address is, and `TokenStorage` exists so the Keychain can be swapped for memory.

```bash
make test             # offline, runs against KandevKit
make test-live        # adds tests that read a real server over the network
make test-live-write  # adds tests that send a prompt to a scratch task
```

The live suites are off unless the environment names a server, and they are
expected to fail without network access. `test-live` reads only and never starts
an agent. `test-live-write` runs both write suites and does start one, so it needs
a scratch task that already has a session running:

```bash
KANDEV_LIVE_WRITE=<scratch-task-id> KANDEV_LIVE_PROFILE=<agent-profile-id> make test-live-write
```

Launch that session first with `session.launch`; a prompt cannot be addressed
without the session's incarnation id. Delete the task afterwards. Never point it
at a task someone is using.

Two things learnt the hard way about these suites:

- The environment must be set on **each** command in the recipe. On one line it
  reaches only the first, and the second suite is skipped while reporting no
  failures. As a target-level export it reached neither, and the suite crashed.
- They are `.serialized`, and a live "nothing should change for N seconds" test
  cannot be written at all: another suite's turn completion lands inside the
  window. Assert that against a captured frame instead.

## Following a conversation live

The transcript follows the agent through `session.conversation.changed`, which is
an ordered operation log, not a message-per-frame feed:

- Subscribe with a `scope_id` this client generates (`core:ios:<uuid>`) and
  `consumer_kind: "core"`. The answer is a handshake carrying `epoch` and
  `revision`.
- Each change carries `base_revision`, `revision`, and `operations` — message and
  turn upserts. A message arrives **again** under the same id as its text grows,
  so it must be merged by id, never appended.
- `base_revision` is the gap guard. If it does not match the revision you hold,
  you missed something: refetch and resubscribe. Do not apply it.
- `check: true` with no operations is a liveness heartbeat, every few seconds.
  Treating it as a change refetches on a timer.

There is exactly **one** consumer of the transport's notification stream, because
an `AsyncStream` gives each value to one reader. That consumer is
`KandevNotificationHub`, one per client, which decodes each frame once and fans it
out. Screens subscribe to the hub; **nothing else may read `client.notifications`**,
because a second reader silently takes half the frames.

The hub tags each task change with what kind it was, and that tag is load-bearing.
A deletion carries the *whole task*, so a list that only looks at the payload
finds the row and patches it in place — and a deleted task patched in place stays
on screen forever. Creation looked fine by comparison for the accidental reason
that a new task is not in the list yet. Both were caught by watching the running
app while creating and deleting a task from the command line, which is worth doing
for any change to this path:

| Kind | What the list does |
| --- | --- |
| `updated` | patches the row in place — no refetch |
| `created` | marks itself behind and catches up, coalescing bursts |
| `deleted`, `archived` | removes the row immediately |

The conversation frames carry a heartbeat every few seconds (`check: true`, no
operations). Treating it as a change refetches on a timer.

## Verifying a screen by hand

Appearance is checked by looking at the app, which means driving it. The
simulator has no tap command and no `idb` on this machine, so the app carries a
deep link for exactly this purpose:

```bash
xcrun simctl launch booted dev.pocketsand.PocketSand
xcrun simctl openurl booted "pocketsand://task/<task-id>"
xcrun simctl io booted screenshot /tmp/shot.png
```

iOS asks "Open in Pocket Sand?" before honouring a cross-app open, and nothing
here can press that button. Launch the URL from a *cold* app and the prompt still
appears, so deep links are for notifications and sharing, not for unattended
verification.

The technique that does work is to open the screen from code: set the initial path
in `TaskListView` to the task's id, build, screenshot, then put it back. Two rules
come from getting this wrong:

- **Mark the edit.** The patch is one line in a file that has an identical-looking
  line, and it is invisible in a diff summary. Write `// TEMPORARY-DEEPLINK` on it,
  and grep for the marker rather than trusting that you reverted it.
- **Do not trust a backup file.** A backup taken while the patch was live restores
  the patch, and then the next build ships a hardcoded task id to everyone. Verify
  the *file* (`grep -n "State private var path"`) and, once it is committed, verify
  the *commit* (`git grep <id> HEAD`) — a working tree can be reverted under you by
  anything else editing the repo.

Two traps worth not rediscovering:

- A plist written into a simulator's container is ignored: that simulator's
  `cfprefsd` has the domain cached. Write settings with
  `xcrun simctl spawn booted defaults write <bundle-id> <key> <value>`.
- An XcodeGen source directory is enumerated when the project is *generated*.
  Adding files to a directory that was empty at generation time adds nothing, and
  the test run reports success having executed zero tests. Run
  `./scripts/xcodegen generate` after adding files.

## Working alongside other writers

This repository has been edited by more than one agent at once, and that is worth
knowing before you trust a clean `git status`:

- **Verify the commit, not the tree.** A file can be reverted under you between
  reading it and committing it; `git grep <thing> HEAD` is the check that catches
  it, and `git status` is not.
- **Stage what you changed, by path.** `git add -A` takes whatever else is in the
  tree at that instant, which is how a reverted `Info.plist` was committed once.
- **Read the log before assuming authorship.** Commits you did not write appear
  between yours; that is normal here, not a mistake to correct.

## Known gaps

- No entitlements yet, so the macOS app is unsigned and unsandboxed. Adding the
  sandbox requires `com.apple.security.network.client`, or the app cannot reach
  any server at all.
