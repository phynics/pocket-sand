# Feature tracker

What the Kandev server can do, what the first-party clients do with it, and what
this app does.

This is a **tracker, not a roadmap.** The third column is a fact, and the fourth is
a decision nobody has made yet. Nothing here is a promise.

Derived from, against **Kandev v0.96.0**:

- The action and route tables in `KandevKit` (`KandevAction`, `KandevHTTPRoute`).
  Every entry there was verified against a live server by sending it and reading
  the answer.
- Upstream's `/ws` reference — [`reference/kandev-websocket-api.md`](reference/kandev-websocket-api.md)
  and the current upstream copy of it. The current one enumerates **279 registered
  request actions** and names about **100 emitted notifications**, and says so
  itself:
  an action constant is not evidence that anything is registered, so the catalog
  was checked against dispatcher registrations.
- The first-party PWA, read two ways: the HTTP calls its bundle makes, and the
  names of its lazily-loaded chunks. The chunk names are a feature inventory
  written by the people who built it — `pty-terminal-view`, `file-diff`,
  `needs-you-inbox-page-client`, `dockview-desktop-layout`, `tiptap-plan-editor`,
  `monaco-init`, `lsp-client-manager`, `canvas-lifecycle`, `workspace-files`.

## The shape of the comparison

**The counts are not the story.** Kandev is a platform with a desktop-class web
client: dockable panes, a Monaco editor with an LSP client, PTY terminals, Mermaid
and KaTeX rendering, secrets, automations, Kubernetes executors, GitHub, GitLab,
Jira, Linear and Sentry integrations. This app is a **phone-first client for tasks
and the conversation inside them**: 22 actions and 8 HTTP routes.

Almost everything in the server's catalog is therefore absent here, by design. The
question a tracker should answer is not "what is missing" but **what a person
holding a phone would notice first** — and that list is at the end, because it is
the only part of this document that asks for work.

Legend — **✅** used · **◐** partial, see the note · **—** the server has it and
this app does not · **·** out of scope on purpose.

## Tasks

| Capability | Server | PWA | Here | Note |
| --- | --- | --- | --- | --- |
| List a workspace's tasks, across workflows | ✅ | ✅ | ✅ | `GET /workspaces/{id}/tasks`. Paginated, and the list loads more as you reach the end. |
| Search tasks server-side | ✅ | ✅ | ◐ | The route takes `query` and `TaskListStore` already passes it; no field drives it. |
| Sort (`updated_desc`, `created_*`, `title_*`) | ✅ | ✅ | ◐ | Hardcoded to `updated_desc`, which is the closest thing to last-activity. |
| Filter by workflow or repository | ✅ | ✅ | — | |
| **Group by project** | n/a | ✅ | ✅ | Client-side, by the task's first attached repository, with the workspace's repository names read for the headings. Subtasks stay under their parents inside their section. |
| Attach a repository to a task | ✅ | ✅ | ✅ | One repository, at creation, from the workspace's list. The create route takes several; the screen offers one, because a phone is not where anyone decides a task belongs to three. |
| Fetch one task | ✅ | ✅ | ✅ | `task.get` carries the session state, activity and step, so a row needs no second call. |
| Create a task | ✅ | ✅ | ✅ | Title, brief, workflow, step, agent. The brief becomes the session's first prompt verbatim. |
| Set the agent a task runs with | ✅ | ✅ | ✅ | Chosen at creation, and preselected to the one that is set up. A profile the runtime cannot vouch for is offered with the caveat said out loud rather than hidden. |
| **Edit a task** (`task.update`, `task.state`) | ✅ | ✅ | — | **The largest gap.** No way to fix a title, extend a brief, or change state from the app. A partial update, with a documented guarantee that concurrent edits to different fields both survive. |
| Move a task between steps | ✅ | ✅ | ✅ | Via HTTP, with a preview of what the move will do first. |
| Move between workflows | ✅ | ✅ | — | The move route is step-scoped. |
| Archive, unarchive, delete | ✅ | ✅ | ✅ | Swipe a row. Delete is refused while the worktree is dirty unless the changes are discarded. |
| Subtasks | ✅ | ✅ | ◐ | The list nests one level and draws the hierarchy. Creating a subtask (`parent_id` on create, the PWA's `new-subtask-dialog`) is not offered. |
| Task plans, walkthroughs, documents | ✅ | ✅ | — | `task.plan.*`, `task.walkthrough.*`, `mcp.*_task_document`. |
| Task metadata, repositories, port forwarding | ✅ | ✅ | — | |
| The board (kanban, columns, drag between steps) | ✅ | ✅ | · | Deliberately not built — [ADR-0002](adr/0002-task-first-navigation.md) chooses a task-first navigation over a board. |

## Sessions and running agents

| Capability | Server | PWA | Here | Note |
| --- | --- | --- | --- | --- |
| List a task's sessions | ✅ | ✅ | ✅ | HTTP, not a `/ws` action in 0.96. |
| Start an agent on a task | ✅ | ✅ | ✅ | Needs an agent profile even when the task records one. |
| Stop a turn | ✅ | ✅ | ✅ | Cancels the work, not the conversation. |
| Follow session state live | ✅ | ✅ | ✅ | `session.state_changed` drives the row's spine. |
| Follow the turn live (start, complete, todos, usage) | ✅ | ✅ | — | `session.turn.started`, `session.turn.completed`, `session.todos_updated`, `session.prompt_usage`, `session.mode_changed`, `session.models_updated`. The app infers a turn's end from session state instead. |
| Rename a session, set it primary, delete it | ✅ | ✅ | — | |
| Reset context, plan mode, recover a session | ✅ | ✅ | — | |
| Choose a model or mode per turn | ✅ | ✅ | — | The queue entry carries a `model` field; the composer does not set it. |
| Agent catalogue (runtimes and profiles) | ✅ | ✅ | ✅ | `GET /agents`. |
| Agent logs, stdin, resize, status | ✅ | ✅ | — | Lower-level controls; task clients are told to use session actions instead. |
| Answer a permission request | ✅ | ✅ | — | `permission.respond`. The spine says a task needs attention; the app cannot answer it. |

## The conversation

| Capability | Server | PWA | Here | Note |
| --- | --- | --- | --- | --- |
| List a session's messages | ✅ | ✅ | ✅ | Cursor-paginated. The page fetched is the **newest** one, and it is turned back into reading order; the wire hands it over newest-first. |
| **Load older turns** | ✅ | ✅ | — | The response carries a cursor and `has_more`; the app fetches one page with `before: nil`. Older history is unreachable. |
| Search messages | ✅ | ✅ | — | `message.search`. |
| Live conversation (ordered operation log) | ✅ | ✅ | ✅ | `session.conversation.subscribe`, merged by message id, with the revision gap guard. |
| The exchange around a turn | ✅ | ✅ | ✅ | Tap any row: the prompt, the steps, the reply, and the reply before it. |
| Turn grouping and durations | ✅ | ✅ | ✅ | One summary control per turn, not per run. |
| Markdown, code blocks, Mermaid, KaTeX | n/a | ✅ | — | The agent's output *is* markdown and the app draws the characters. Its own preamble arrives as literal `##` and `-`. |
| Files, diffs, file review, commits | ✅ | ✅ | — | `workspace.files.*`, `session.file_review.*`, `session.git.*`, `file-diff`. |
| Todos panel | ✅ | ✅ | — | `session.todos_updated`. |

## Chats: quick and configuration

A chat is not a separate object on the server. Starting one creates a **task and a
session** and answers with both ids, which is why this client can open one in the
transcript it already has.

| Capability | Server | PWA | Here | Note |
| --- | --- | --- | --- | --- |
| Start a quick chat | ✅ | ✅ | ✅ | `POST /workspaces/{id}/quick-chat`. Offered as a door on the create screen, and named after the sentence rather than "agent - Chat 3". |
| Find a chat again | ✅ | ✅ | ✅ | In the task list, in a **Chats** section. The server marks them `is_ephemeral`, which is how the first-party client knows to hide them — this client shows them, because a chat is where a task that matters often starts. |
| Start a configuration chat | ✅ | ✅ | ✅ | `POST /workspaces/{id}/config-chat`. Offered where the need arises: the create screen, when there is no agent to start anything with. |
| List existing chats | ✅ | ✅ | — | `GET /workspaces/{id}/quick-chats` is written down and verified; nothing calls it yet, and a chat that is not in the task list has to be found somewhere. |
| A chat's own tab, ordering, superseding | ✅ | ✅ | — | The first-party client keeps chats as tabs per workspace and deletes the task behind a superseded one. This client opens a chat as a task, because that is what it is. |
| File a chat as a task | ✅ | ✅ | — | The point of the design — nothing written is thrown away — and not built: it is `task.update` with a workflow. |
| Suggestions in a configuration chat | ✅ | ✅ | — | The first-party client offers four canned prompts (add a review step, create a profile, show the workflow, update MCP). |

## The composer

| Capability | Server | PWA | Here | Note |
| --- | --- | --- | --- | --- |
| Send a prompt | ✅ | ✅ | ✅ | Four ids required, so a prompt cannot be sent before the session record is held. |
| Interrupt and send now | ✅ | ✅ | ✅ | |
| Queue while a turn runs | ✅ | ✅ | ✅ | Server-side queue, max 5 on a live server. |
| Read and cancel the queue | ✅ | ✅ | ✅ | |
| Take one entry back, reorder, edit, merge | ✅ | ✅ | — | `message.queue.remove`, `.reorder`, `.update`, `.merge`. The queue model already parses the entries. |
| Auto-run and auto-merge settings | ✅ | ✅ | — | `message.queue.auto_run.set`, `.auto_merge.set`. |
| **Attachments** | ✅ | ✅ | — | `KandevQueue.attachments` is already parsed, and the server has an overflow code for it; the composer sends text only. A phone has a camera. |

## Workspaces and workflows

| Capability | Server | PWA | Here | Note |
| --- | --- | --- | --- | --- |
| List workspaces, with scopes | ✅ | ✅ | ✅ | Permissions arrive with the list. |
| Switch workspace | ✅ | ✅ | ◐ | Server bookmarks and a `...` menu; the app does not hold a workspace picker. |
| List workflows and their steps | ✅ | ✅ | ✅ | Fetched once, because each workflow carries its full prompt as kilobytes. |
| Create, edit, delete, reorder workflows and steps | ✅ | ✅ | — | HTTP/configuration surfaces, not ordinary `/ws` requests. |
| Workspace members, roles, ownership transfer | ✅ | ✅ | — | |
| Workspace statistics | ✅ | ✅ | — | |

## Live updates

The app subscribes to the hub, which decodes each frame once and fans it out.
Eight notification actions are handled; the server names about a hundred.

| Notification | Here | Note |
| --- | --- | --- |
| `task.created`, `.updated`, `.deleted`, `.archived` | ✅ | The kind tag is load-bearing: a deletion carries the whole task, so a list that only patched by payload would keep a deleted row forever. |
| `task.state_changed`, `task.status_summary.updated` | ✅ | The second arrives far more often — thirteen times to five during one live turn. |
| `session.state_changed` | ✅ | Drives the spine's condition, rate and weight. |
| `session.conversation.changed` | ✅ | The ordered operation log, with the heartbeat treated as a heartbeat. |
| `message.queue.status_changed` | — | The queue strip is refreshed on demand rather than followed. |
| `session.turn.*`, `session.todos_updated`, `session.available_commands`, `session.mode_changed`, `session.models_updated` | — | |
| `workflow.*`, `workspace.*`, `repository.*`, `executor.*`, `environment.*`, `agent.profile.*` | — | |
| `github.*`, `gitlab.*`, `office.*`, `system.job.update` | — | |
| Push notifications while the app is closed | — | Not in the protocol at all; it would need APNs and a server-side sender. |

## Everything else the server has

Listed so that a future reader knows the shape of what is not here, and that its
absence is a decision rather than an oversight. None of it is planned.

| Area | What it is |
| --- | --- |
| Repositories, repository sets, scripts | `repository.*`, `repository.script.*` |
| Git and worktrees | `worktree.*` — stage, commit, push, rebase, reset, create a PR |
| Files | `workspace.file.*`, `workspace.tree.get`, `workspace.files.search` |
| Terminals and shells | `shell.*`, `user_shell.*`, `pty-terminal-view`, `quick-terminal-tab-view` |
| Ports and tunnels | `port.*`, `port.tunnel.*` |
| Executors, environments, SSH, Kubernetes | `executor.*`, `environment.*`, `ssh.*` |
| Editors | `vscode.*`, `monaco-init`, `lsp-client-manager` |
| Secrets | `secrets.*`, including `secrets.reveal` — local-administration operations, and the reason the lack of WebSocket authentication is security-critical |
| Automations | `automation.*`, triggers, webhooks, run history |
| GitHub and GitLab | `github.*`, `gitlab.*` — watches, PRs, reviews, CI |
| Jira, Linear, Sprites | `jira.*`, `linear.*`, `sprites.*` |
| Canvases and Office | `canvas-lifecycle`, `office-routes` |
| Clarification inbox | `clarification-inbox`, `needs-you-inbox-page-client`, `mcp.ask_user_question` |
| MCP transport shims | 52 `mcp.*` actions. Raw `/ws` rejects every one of them; they back the agent bridge. |
| Users and settings | `user.get`, `user.settings.update`, `GET /users` |
| Internationalisation, themes | `i18n`, `useTranslation`, `app-theme` |

## What a person holding a phone would notice first

Ordered by how quickly it bites, not by how much work it is. This is the only part
of this document that asks for anything.

1. **Edit a task.** There is no way to fix a title or extend a brief from the app,
   and `task.update` is a partial update with a documented concurrency guarantee.
   This is the gap most likely to send someone to a desktop.
2. **Search.** The route supports `query`, the store already passes it, and only the
   field is missing. Looking something up is what a phone is for.
3. **Older turns.** The transcript fetches one page — the newest — so a long
   session's *history* cannot be reached at all, and the cursor for it is already
   in the response.
4. **Take a queued prompt back.** You can cancel the whole queue but not one entry,
   and the entries are already parsed.
5. **Attachments.** The wire type is already there. A phone has a camera and a photo
   library, and an agent that cannot see a screenshot is a smaller agent.
6. **Answer the thing that needs attention.** The spine says a task is waiting; the
   app cannot answer. The first-party client gives this a whole inbox.
7. **Render markdown.** Not a server feature — the agent's own output is markdown,
   and it is the first thing on screen in every task.

Deliberately not on this list, and not oversights: the board, Git, files, terminals,
ports, executors, secrets, automations, and the integrations. Each is a desktop
concern, and each is a project rather than a screen.

## Keeping this honest

Two entries in the spec tables are **verified but unused on purpose** — `health` and
`features`, the cheapest ways to identify a server and read its flags. `AGENTS.md`
says spec tables may hold those; this document is where the rest of the surface is
recorded so that the same tolerance does not spread to code.

When adding a feature, update the row rather than adding one, and move the item out
of the list above if it was there. When a row's note says "the store already passes
it" or "already parsed", that was true at the commit that wrote it — check before
quoting it as an estimate.
