# Docs

Four kinds of document, and they answer different questions. Everything here is
written to be read *after* the code it describes, as the record of why it is the
way it is — so when a document and the code disagree, the code is what runs and
the document is what needs fixing.

| Where | Answers |
| --- | --- |
| [`../CONTEXT.md`](../CONTEXT.md) | What the words mean. The glossary, and the naming rules that follow from it. |
| [`../AGENTS.md`](../AGENTS.md) | How to work in this repo: boundaries, the protocol pin, how to verify. Written for a person or an agent picking it up cold. |
| [`design.md`](design.md) | What the app looks like and why — the palette, the three voices, glass, and the things that were tried and rejected. |
| [`features.md`](features.md) | What the server can do, what the first-party clients do with it, and what this app does. A tracker, not a roadmap. |
| [`adr/`](adr) | Decisions that are expensive to reverse, one per file, with the alternatives that were considered. |
| [`reference/`](reference) | Upstream documents, vendored so they can be read offline. Not ours, and not necessarily current. |

## The decisions so far

- [`adr/0001-raw-websocket-over-mcp.md`](adr/0001-raw-websocket-over-mcp.md) —
  why this client speaks the server's `/ws` directly instead of going through MCP.
- [`adr/0002-task-first-navigation.md`](adr/0002-task-first-navigation.md) — why a
  task is the object you navigate to, rather than a thread.
- [`adr/0003-tests-cover-the-model-layer.md`](adr/0003-tests-cover-the-model-layer.md) —
  why there are no view tests, and what that obliges the code to do instead.
- [`adr/0004-screenshots-are-a-review-lever.md`](adr/0004-screenshots-are-a-review-lever.md) —
  how appearance gets checked when there is no way to tap a simulator.

## Adding to this directory

- **A decision that constrains future work** goes in `adr/`, numbered, in the
  format the existing ones use: the decision, the context, the alternatives, and
  what it costs. If it is cheap to reverse, it is a commit message, not an ADR.
- **A change in what the app looks like** goes in `design.md`, under the section
  it belongs to, *including* what was rejected and why. The rejections are the
  part that keeps a decision from being re-litigated every few months.
- **A vendored upstream document** goes in `reference/`, with the version or
  commit it was taken from. Say where it came from and how stale it is; the
  server's `/ws` reference here documents an older surface than the server sends,
  and that is worth knowing before trusting it.
- **A capability that exists on the server and not here** goes in `features.md`, as
  a row in the area it belongs to. Update the row rather than adding one; the
  document is only worth reading while each row is still true.
