# Protocol probe

`discovery.json` sends every action this client depends on with an **empty
payload**. Kandev answers each one with a `VALIDATION_ERROR` naming the field it
needed, so the required fields can be read off the wire rather than guessed.

```bash
make probe-v1                      # against the default server
make probe-v1 KANDEV=http://box:38429
```

To see a success response instead, fill in a real id: run `workspace.list`, then
`workflow.list`, then `task.list`, then `task.get`, then `message.list`. Each
response carries the ids the next call needs.

Prefer `scripts/probe-one.sh '<action>' '<payload json>'` for single calls.

This is the re-verification path for a version bump. When `KandevWireVersion`
moves, run it before trusting any field name.
