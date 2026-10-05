# Navigate by Task, not by Thread

This app borrows T3 Code's interaction model, and T3 Code's spine is the Thread:
a durable conversation. We use Kandev's Task as the primary object instead, with
the Task's Sessions reachable from a switcher inside the detail view.

The server owns the truth and has no Thread, so a client-side union of task and
session would be a fiction that drifts whenever a task is archived, deleted, or
given a subtask. Making Sessions primary would discard the workflow position,
which is the only thing a Kandev client offers that T3 Code does not.

## Consequences

- A task list row carries the task's workflow step, because the step is the
  reason to look at the list at all.
- The transcript belongs to a session, and lives one level below the task.
- Any feature that wants "the conversation" must say which session it means.
