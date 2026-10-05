# Pocket Sand

A native macOS and iOS client for a Kandev server. It presents Kandev's tasks as
conversations, borrowing the interaction model of T3 Code.

These terms carry the meanings the Kandev server gives them. We use Kandev's
words rather than inventing our own, so that a conversation about this app and a
conversation about the server stay the same conversation.

## Language

**Task**:
The work to deliver, and the primary object this app navigates. A task holds a
title, a prompt, a workflow position, repository attachments, zero or more
sessions, and one shared plan.
_Avoid_: Card, ticket, issue, work item, thread

**Session**:
One agent conversation attached to a task. A task can have several, and they
share the task's environment.
_Avoid_: Thread, chat, run, agent

**Primary session**:
The session a task treats as its default target. When a task has several
sessions, the app opens this one first.

**Turn**:
One human-to-agent cycle within a session: a prompt, the agent's work, and the
point where it stops.
_Avoid_: Message, exchange, request

**Queued prompt**:
A prompt accepted while a turn is still running, held until that turn ends.
Sending one is not the same as the agent having seen it.
_Avoid_: Pending message, draft, backlog

**Workspace**:
The scope that contains repositories, workflows, tasks, and defaults. Every task
belongs to exactly one.

**Workflow step**:
A task's current process position, such as Backlog, Work, Review, or Done. It is
a process position and not proof that anything ran: moving a task between steps
does not mean an agent worked, code was committed, or review passed.
_Avoid_: Column, status, stage

**Plan**:
A task's single editable Markdown plan, with version history. One per task,
shared by all of its sessions.

**Archived**:
A task taken off the active board. Nothing is deleted, and it can come back.
_Avoid_: Closed, deleted, removed

**Deleted**:
A task removed for good. Not reversible, and its worktree's uncommitted work goes
with it.
_Avoid_: Archived, trashed

## This app

**Task list**:
The app's home. A flat, single-column list of one workspace's tasks, where each
row carries the task's title, its workflow step, and when it was last active.
_Avoid_: Threads, threads view, board, deck, inbox

**Workflow catalogue**:
The workflows of one workspace and their steps, read once and shared by the
screens that need them. The task list reads a step's name and colour from it, and
the new-task form and the step menu read their choices from it, so a step is read
once however many screens ask.
_Avoid_: Board, column list
