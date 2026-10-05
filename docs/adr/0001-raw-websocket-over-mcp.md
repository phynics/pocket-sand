# Talk to Kandev over its raw WebSocket, not its MCP surface

Kandev documents external MCP (`/mcp`) as its supported integration path, but MCP
exposes a set of tools rather than a live event stream: a client built on it
cannot render assistant text as it streams or observe a turn's lifecycle, which
is the entire reason this app exists. We therefore speak the raw `/ws` protocol,
and concentrate every action name, payload, and envelope in one `KandevProtocol`
module.

Kandev labels `/ws` an internal protocol that can change without notice, so this
is a deliberate bet on a less stable surface. The mitigation is the module
boundary and a `kandevVersion` constant: protocol drift should be a change to one
module and one version number, not a hunt through the codebase.

## Considered Options

- **MCP only** — the supported surface, but tool-shaped and poll-driven. Rejected:
  no streaming, so the app would feel dead.
- **WebSocket for streaming, MCP for mutations** — rejected as two integration
  surfaces and two failure modes for a single proof of concept.

## Consequences

`/ws` is most of the API, not all of it. Some reads exist only as HTTP routes,
and the session list for a task is one of them: the first-party web client calls
`GET /api/v1/tasks/{taskId}/sessions`. The client therefore needs a small HTTP
surface alongside the socket. This was discovered by probing a live server after
the decision was made, and it contradicts an earlier assumption of ours that
REST was dead code.

The raw protocol also has two different failure shapes, and one of them arrives
inside a frame that otherwise looks successful. Failure classification lives in
one place (`KandevFailure`) so no call site can forget to check it.
