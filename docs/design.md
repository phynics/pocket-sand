# Pocket Sand: the visual system

Working notes, kept because the reasoning is not visible in the code and would
otherwise be re-derived (or accidentally reversed) by the next person.

## The subject

A remote control for coding agents running on your own server. Read the board,
see who is working, read what the agent actually did, intervene. One developer, on
a phone, one-handed, in a hurry, often in the dark.

Its primary job: **tell me in one second which task needs me, then let me read
what the agent did.**

## The two decisions everything else follows from

### 1. The app has no colour of its own

Six achromatic values, and every hue on screen comes from the workflow step
colours the server already sends, plus the system's destructive red.

| Token | Light | Dark |
| --- | --- | --- |
| `paper` | `#F5F5F2` | `#000000` |
| `surface` | `#E6E6E0` | `#16161A` |
| `ink` | `#15171B` | `#F2F2F4` |
| `graphite` | `#43464C` | `#B4B4B9` |
| `muted` | `#63635C` | `#8E8E93` |
| `rule` | `#D0D0C8` | `#2E2E32` |

**Light mode is paper. Dark mode is the void.** Off-white with a whisper of warmth
and a grain, against pitch black with none — texture on true black would lift it off
black and undo the point of it.

The values were chosen against measured contrast rather than by eye: ink on paper
16:1 and ink on black 19:1; muted 5.5:1 on paper and 6.4:1 on black, which keeps a
clear step below ink without becoming hard to read at caption sizes; the rule a
hairline that is visible (1.4:1) and still quiet; the surface step just enough to
read as a block (1.15:1).

**Three text values, for three kinds of thing.** Ink is what somebody *said* — a
person's question, an agent's answer. Muted is an aside: a label, a step's own name,
a fact you glance at. `graphite` is what the machine is *doing*: the line under a
run, and the step currently being written. Those two are the only text on the screen
that changes without anyone touching it, and at full ink they were the loudest thing
in a conversation they only narrate — "Ran for 11 seconds" was set in ink at medium
weight, which made a counter heavier than the answer it counted. It is 8.9:1 on paper
and 10:1 on black: a clear step below ink, a clear step above muted.

An answer stays at ink. Softening what somebody said, in order to tell it apart from
what a machine is doing, would be the wrong way round.

### The grain

Generated once from a fixed seed, so it is the same texture every launch — a
texture that changed would read as noise rather than as the surface you are looking
at. 48 device pixels, black speckles at up to 5% alpha on about a third of pixels,
measured back off a screenshot at 232–245 against a 245 base.

Two things it took to get there, both invisible in the source and obvious in the
pixels:

- Premultiplied alpha means black with alpha is `(0, 0, 0, a)`. Storing a dark grey
  at alpha 1 is malformed premultiplied data, and CoreGraphics resolved it into a
  uniform wash instead of grain.
- `Image(decorative:scale:)` has to be told the display scale. At the wrong scale
  the tile is resampled, and resampled grain stops being grain and becomes a tint.

This is not restraint for its own sake. It settles a real argument: the server
colours process position, so any accent this app introduced would compete with the
one signal on screen that carries meaning. **Attention is therefore ink, not a
hue**: an unread row is set in ink and a read one in muted grey, a task that is
asking something has a spine that breathes twice as fast as one that is working,
and a failed one borrows the system's red. (A small solid square in the row's
corner did this job first; it read as a stray artefact, and it is gone.)

The rule reaches the platform's own controls too. `AccentColor` is ink, so a
toolbar button or a menu is not quietly blue, and a swipe action that is not
destructive is the platform's neutral grey.

### 2. Three voices, three faces

The screen *is* a transcript: a record of who said what. Type therefore says which
voice is speaking rather than decorating a screen.

| Voice | Face | Where |
| --- | --- | --- |
| A person | New York (serif), body | task titles, prompts |
| The agent | SF Pro, a size down | its replies |
| A machine | SF Mono | commands, exit codes, agent identifiers, timings |
| Chrome | SF Pro | labels, controls, counts |

Hierarchy comes from size and space, not from a stack of weights. The serif
transcript in a developer tool is the deliberate risk: it is uncommon, and it is
the thing that makes the app recognisable.

**The agent was serif and is not any more.** An agent writes at length — a reply is
often a page of it — and at body size in a serif its answers weighed as much on the
page as the questions they answered, which is backwards: the question is what you
came to the exchange for. Sans is narrower, so a line holds more of it, and the size
step down is what keeps the person's own words the loudest thing on the screen.

The cost is honest: the agent's prose and the chrome are now the same face, told
apart by size alone. That is a smaller loss than it sounds — chrome is a line or a
label and the agent's text is a paragraph, so the two never sit at the same size in
the same place — but it is a loss, and it is why the person's voice stays serif. If
the app ever needs the agent to be recognisable at a glance rather than by reading,
the face to change is the chrome's, not the agent's.

## Structure

No cards anywhere. Structure comes from rules, a shared left edge, and space.

A **voice**, though, is not structure. The two voices of the transcript speak in the same block —
one width, one shape, one corner — and the whole of the difference is which way the light falls on
it. An agent's answer is a sheet raised off the page: light from the top left, shade thrown to the
bottom right. A person's question is pressed into it, which is the shape it arrived in, because it
is the same well the composer is. The two share one paint, so they cannot drift apart; and an agent
that asks a question of its own speaks in the well too, because a question is a question.

Neither is a card. A card is a container *for* structure and has an edge of its own; a block's fill
is the material it lies in, so the only thing marking where it begins is the light, and no line is
drawn across the page. It is also the one depth treatment that cannot cost contrast — the words stay
ink on paper and the whole of the depth is outside them — which is what lets it carry a page of
answer without competing with the question it answers.

Both blocks reach twelve points past the transcript's gutter and are padded inside by the same
twelve, so every voice starts on one left edge: a question, an answer, and the steps between them.
That reclaims twelve of the gutter's sixteen points and leaves four, which is what the narrowest
phone this runs on needs.

In the dark the shadows cannot work, and for a reason worth writing down: a shadow needs a surface
to fall on, and true black has none. So each block moves itself instead — the sheet rises a step in
its fill, and the well keeps the `surface` step it has always had, because there is no below-black
to press into — and the fill's own light says which is which.

- **A task's step is a 3pt spine at the screen's leading edge**, in the step's own
  colour — not a filled pill. Scanning down the list gives a colour column rather
  than a stack of badges, and the step's name sits under the title where it reads
  as part of the sentence about the task.
- **A turn is separated by a hairline** with its duration at the trailing end in
  mono. No "Turn 4" heading: the rule is the boundary, and a label would be a
  typographic device doing a rule's job.
- **The queue is numbered**, because a queue genuinely is a sequence and the
  position is the part that changes.
- **The header is pinned**, not at the top of the scroll view. Opening a task
  lands at the newest message, so a header in the scroll is the one part never
  seen — and it holds the two facts you need: where the task sits, and who is on it.

## Telling one folded row from another

A folded row used to carry a chevron and nothing else, which says "there is more
here" without saying what "here" is. Each kind now leads with a glyph, and the
chevron moved to the trailing edge: the left of a row is what it is, the right is
that it opens.

| Row | Glyph |
| --- | --- |
| A thought | `brain` |
| A tool call | `wrench.and.screwdriver` |
| A script | `terminal` |
| Folded work of a turn | `square.stack.3d.down.right` |
| Older work of a run | `ellipsis` |

## Folding

Three folds, at three scales, all showing the same thing: enough to know what is
there, and the way to see the rest.

| Fold | Shown |
| --- | --- |
| A finished turn | its question and answer; the work between them becomes "21 steps" with the duration |
| A thought | its first line, in italic serif. "Thinking, collapsed" told you nothing you could not already see |
| A long command | its first line, in mono. One line can still be five wrapped lines |
| A run's older steps | nothing. Its last five are on screen and the rest are a count: during a live turn the tail is what answers "what is it doing" |
| A step an agent repeated | one line and a count. Twenty identical commands say nothing that `×20` does not |

Folding repeats is **consecutive and identical only**. Two bursts of the same command
either side of a different step are two events, and folding them would misreport how
the agent worked.

The control over a run's older work works **both ways**: closed it offers the hidden
steps, open it offers to put them back. Expanding an eighty-step run with no way to
fold it again leaves a screen you scroll out of by hand. It is also **per run** — the
tap is about the run under the finger, not a statement about every run on screen.

A folded row speaks in the voice it will speak in when opened — a thought in serif
italic, a command in mono. The first version set both in mono, and a run of
alternating thoughts and commands read as one flat grey block.

Folding is by **run**, not by reordering. A turn is usually question, work, answer,
but an agent that speaks between tool calls would have its words moved past them by
a condensing that sorted rows into kinds. The run replaces rows where they stand.

### The line under the work

A turn's folded summary used to sit *above* the steps it counted, and read "Worked for
3m 7s · Read 9 files and ran 53 commands". It is now underneath them, and says
**"Running for 3 minutes and 35 seconds; Read 9 files and ran 53 commands"**:

- **Underneath, because it is a conclusion.** Above the work it was a claim about
  steps that had not happened yet. It sits under the last step it counts — which in a
  live turn is the bottom of the screen, and the reason the change was asked for.
- **Spelled out, because it is a sentence.** "3m 35s" is a label; "3 minutes and 35
  seconds" is how someone says it out loud. Two lines are allowed, so the whole thing
  wraps rather than being cut mid-phrase.
- **"Running for", not "Ran for", while it runs.** The tense is the state: a line that
  says "ran for" about work in progress is a lie, and the same line becomes "Ran for"
  when the turn ends. Nothing else has to say whether the agent is still going.
- **A running turn is timed from its own start**, because the server has not dated an
  end that has not come. A finished one is timed by the server, which counted the whole
  of it. The clock ticks once a second — only a working turn gets a timer, since a
  finished one has nothing to count.

**The movement says progress.** As a step finishes it leaves the five-line tail and the
summary takes the count, so the rows slide up and out (`.transition(.move(edge: .bottom))`,
animated on the *set* of row ids) and the numbers in the line roll rather than jump
(`.contentTransition(.numericText())`). That is the only thing on the screen that changes
without anyone touching it, and it is why the line does not need a spinner.

## Text size

Checking the app at the accessibility text sizes was the first thing the screenshot
flow did that reading code could not, and it found four defects in a screen I had
already looked at a dozen times. The rules that came out of fixing them:

- **A row that holds a label and an answer needs two arrangements.** At
  `accessibility-extra-extra-large` one line cannot hold both, and what happens then
  is not a smaller answer — it is `Filed in  No wo…`, an ellipsis where the answer
  should be. `ViewThatFits` tries one line and falls back to the label over the answer,
  which is why the answer is neither truncated nor shrunk.
- **A row of three named things stacks.** "Task Chat Setup" at those sizes broke
  *inside* the word — "Set-" / "up" — and a hyphen is the layout admitting it has
  nowhere to put the word. Stacked, each gets its own line and its own rule.
- **A placeholder in a growing field does not wrap, it truncates.** `Fix the flaky
  t…` is worse than no example at all, so at the accessibility sizes the example goes
  and the field's label — which is always there and always legible — does the work.
- **A failure is a failure at every size.** The task list drew its load failure as a
  muted grey paragraph, which at these sizes became a screen-filling grey wall that
  read as a note about the list rather than as the reason it was empty. It gets the
  same red mark and ink words every other failure in the app gets.

None of these were visible at the default text size. They are the argument for the
screenshot flow in one paragraph: the app is used at sizes the developer is not using.

## Motion

One thing moves without being touched: a row's spine, which dims and brightens while
an agent works — slowly — and twice as fast while it is waiting on an answer. It
answers the question the user is actually asking. It is off under Reduce Motion,
and that is not a loss — the spine stays solid and still says the same thing. A
floor of 0.55, not 0.3: a three-point spine at 30% reads as a missing row.

Everything else that moves was asked for: a fold opening (`Motion.fold`, off under
Reduce Motion), and the transcript's live line, whose rows slide out and numbers
roll as the turn the reader is watching progresses (see "The line under the work").

## What looking at it changed

Built, screenshotted, critiqued, revised. Things that only showed up on screen:

- `.listRowInsets` applied to a `List` does nothing; on the rows, the spine starts
  at the screen edge and forms the colour column the design is built on. Before
  that it sat inset and read as a mark on each row.
- "43 minutes ago" costs a third of a phone's width and pushed titles into an
  ellipsis. `CompactAge` writes `43m`; the full phrasing is in the accessibility
  label, where width is not a constraint.
- A turn of 186.7 seconds read as **"186,7s"** on a device with a decimal comma,
  because `formatted()` is locale-aware. `CompactDuration` writes `3m 7s`.
- The pulse at 0.3 made a working row look like a missing one.

## Liquid Glass, used twice

Glass is a material for the navigation layer and never for content, and it earns its
place by having something behind it to refract. Over a flat colour it is a
translucent grey, which is decoration. That gives exactly two uses in this app:

1. **The composer**, which floats over the transcript's foot.
2. **Its action button**, in the same `GlassEffectContainer` — glass cannot sample
   glass, so apart they would each carry a separate backdrop and read as two
   unrelated surfaces.

Both are tinted towards the appearance rather than left clear, and the tint differs
by mode for a reason. Untinted over a transcript, the rows behind ghost through at
full contrast and the control's own words compete with the conversation passing
under them. In dark mode untinted does something worse: glass over pitch black
resolves to a grey panel, a slab of light in an interface whose dark identity is the
absence of one. Each appearance therefore tints towards itself — paper in light,
black in dark — and what is left of the material is the blur and the edge.

**This was removed once and put back, and the reason it came back is worth keeping.**
The composer was rebuilt as a plain field on paper with a rule above it, on the
argument that a material there was a surface inside a surface. That argument is not
wrong, and the plain version was legible and quiet. What it lost was the thing the
material was doing: the transcript is the only content in this app that moves under a
control, and the composer is the only control with something to refract. A rule and an
opaque bar say "a different region"; glass says "the conversation is still there,
underneath" — which is what a composer over a live transcript should say. So the
question to ask before removing it again is not whether the plain version reads
fine, because it does, but whether anything else in the app is doing the job the
material was hired for.

Three applications were tried and rejected, and the rejections are the interesting
part:

- **The transcript's header as glass.** It looked good in isolation and was wrong on
  real data: the conversation ghosted through it and fought the agent's name, which is
  the one thing the line exists to say. It is a facts line, not a control surface, and
  it is back to opaque paper with its rule.
- **Glass on the composer before the layout allowed it.** The composer was a sibling
  of the scroll view, so nothing passed beneath it and the glass had nothing to do. It
  became an inset first; then the material had a job.
- **Glass on the rows themselves.** A list row is content. It gets a rule and a spine,
  and no material at all.

Checked at Increased Contrast with accessibility-large text: Dynamic Type scales
cleanly, since every face here is a relative text style, and the glass holds at both.
Reduced Transparency is not settable through `simctl` on this machine, so it is
unverified.

## What the console said

Running the app produces a wall of log noise. Read rather than filtered, it breaks
down as:

- **Unsatisfiable constraint warnings** — all of them inside `TUIPredictionViewCell`
  and `TUICandidateGradientContentLabel`, which is Apple's keyboard prediction bar
  with a zero-width cell. None in this app's hierarchy.
- `runningboard` "Client not entitled", `UAFAssetSetConsistencyToken` with an empty
  boot UUID, `SFBarButtonGroupContainerAccessibility` not found, and the
  `UIKBDynamicRenderFactory` lines: simulator noise, unrelated to the app.

One real problem was behind "some performance issues", though, and it was mine: the
transcript had been a plain `VStack` since the render tests needed one, and the render
tests were deleted without the `LazyVStack` coming back. A run can be eighty steps,
each with a glyph, a hairline and sometimes glass, and the transcript changes on every
message an agent emits — so every row was being rebuilt on every frame of a live turn.

## Creating something

A task, a quick chat and a configuration chat are **one object on the server**. A
chat is created with a session already attached and a task behind it; what makes
it a chat is that it is not filed. So the screen that creates one is not a form
with modes, and the story it tells is this:

> Everything starts as a sentence. Two doors keep it; the third fixes what is in
> the way.

**There is one input.** The server makes the sentence the agent's first message,
word for word, so the sentence is the only thing anyone has to write — and the
task's name is taken from its first few words rather than asked for. A screen with
one field is a screen where nobody has to work out which field is which, which is
what the first version got wrong: two serif placeholders, no labels, and no way to
tell the title from the prompt.

**The doors are at the top, named.** A chat is not a hidden gesture and the setup
chat is not something you have to be stuck to find:

```
   ✕                                            Create
   Task          Chat          Setup              the chosen one in ink, ruled
   ─────────
   What needs doing?                              the label, above the field
   ┌────────────────────────────────────────────┐
   │ Fix the flaky test in the auth suite       │  the well: a field is the one
   └────────────────────────────────────────────┘  filled thing in this app
   The agent receives this as its first message, word for word.

   Where it goes
   Filed in    Development · its start step   ⌄   ans answer in ink, chevron in ink
   Agent       Claude Code                    ⌄
   Repository  None configured                    a statement, not an empty menu
```

Filing is **one decision, not two**, so it is one row opening one menu of workflows
and their steps — not four pickers. Every row shows an answer rather than asking a
question, and every answer was chosen before anyone arrived.

**The type says which lines are yours.** The sentence is New York, inside the app's
own field well, because it is the only thing that is yours. The rows are SF Pro in
the app's own voice, labels muted and answers in ink. That is the same grammar as
the transcript — serif is a person, sans is the agent and the chrome — so the screen
needs no legend.

**A field is the one filled container this app has.** No cards anywhere, but a field
is a container for your words, and the composer established the shape first. The
create screen uses the same well rather than a bare line of serif text, because a
placeholder on paper with no border is not a place — it is words that happen to be
there.

### What the first version got wrong

Built, then looked at, then rebuilt. Both rounds of mistakes are worth keeping:

- **Two unlabelled fields.** A large serif placeholder asking "What needs doing?"
  above a smaller one saying "Title", with no labels. Which one is the prompt? Which
  is the name? Neither, apparently, and the second placeholder disappeared the moment
  anyone typed in the first. There is one field now, and its label is a label.
- **Nothing looked like a field.** Removing the card removed the affordance with it: a
  placeholder on paper is text, not a place to type. The wells came back.
- **The title was a field at all.** The server requires a title, and the first few
  words of the sentence are a better one than anything anyone would type twice.
- **The doors were at the bottom.** Under the fold, and one of them behind the
  keyboard, so the "other ways to start" were invisible on the screen whose whole
  argument they are.
- **The workflow row did not look pickable.** Muted chevron on a muted value: nobody
  knew the workflow could be changed. The answer in ink and the chevron in ink.
- **A menu that opened onto nothing.** A workspace with no repositories got an empty
  menu. It gets a statement and the way to fix it instead.

### What was rejected

- **A segmented control for the doors.** It is a filled container, which this app
  does not use, and it would make *which door* the first thing you see — a wizard,
  asking before you know what you want.
- **A chevron (`›`) on the rows.** That is the navigation vocabulary the task rows
  deliberately dropped. The glyph here is the platform's own
  `chevron.up.chevron.down`, which is what a menu picker shows: "this opens a
  choice", not "this goes somewhere".
- **Asking for a repository or an executor.** The create route takes repositories,
  but the workspace has its own, and on a phone a repo picker is a heavy, rare
  choice. An executor is not in the create contract at all — the server derives it
  — and asking for something the server decides is a lie.
- **A separate chat screen.** A chat is a task with a session, so "Just ask"
  creates one and opens the transcript the app already has. The payoff is that
  nothing is thrown away: filing a chat later adds a workflow to a task that
  already exists.
- **The helper text under the brief.** It explained that the brief becomes the
  first message, which the screen now *is*. It shows only while the field is
  empty, and then gets out of the way.
- **A title field, in the end.** Kept at first on the grounds that a task cannot be
  renamed yet, so a title nobody could edit was a trap. But the title is derived from
  the sentence and the server can generate a real one with an agent, so the trap was
  the field, not the absence of one.

### What looking at it changed

Seen on an iPhone against a real server, and four things were wrong that no amount
of reading the code would have shown:

- **The writing area was in a card.** A `Form`'s inset sections are filled
  containers with a white background, which is exactly what this app does not use —
  the sentence was in a box sitting on the paper. A plain list and no row
  background puts it on the paper.
- **The agent row was a `Picker`,** which renders its own value in the system's
  secondary grey, so the two rows of one sentence did not match: "Filed in" had an
  ink answer and "Agent" a grey one. Both are built the same way now.
- **The setup row was dressed as a menu** — a value and a choose-chevron — when it
  is the one thing to do rather than a choice among several.
- **The keyboard hid half the argument.** Focusing the sentence pushed the second
  door and the agent's caveat below the fold. Not focusing it shows the whole screen
  at once, which is the point: what you are asking for, where it goes, who takes it,
  and the other way to start.

The three notes on the screen are each triggered by a state — the field is empty,
the agent is unconfirmed, the door is disabled — so in the ordinary case at most
one of them is showing.

### When there is no repository

The same argument as the setup chat, one step smaller: a workspace with no
repositories gets a statement — *"None configured"* — and a note naming **Setup** as
the way to add one, which is where the setup chat can create a GitHub repository or a
path on the machine running Kandev. A control that opens onto nothing is worse than
no control.

### When nothing is set up

The screen's third door is the one that matters most, and it is not a door for
starting work. With no agent profile, neither of the others can open — and a
disabled button beside the words "no agent profiles" is a screen someone cannot
get out of. So the create screen offers the **setup chat** where the need actually
arises, rather than in a settings screen nobody has found:

```
   No agent is set up
   Change the setup                       Setup chat
   Nothing can start until there is one. The setup chat can make one — it
   changes Kandev's own settings, not this task's.
```

That is the cohesion the whole design turns on: the configuration chat is not a
fourth mode of creation, it is **the agent that edits the app, reached from the
thing that is in the way**.

## Deliberately not done

- **No `ContentUnavailableView`.** Empty states are `EmptyNote`, set in the app's
  own faces, because the default component speaks in a different visual language.
- **No boxed text field, and no rule either.** The field sits in a shallow capsule
  well: depth rather than a line. A hairline under it was a straight rule drawn on a
  material, reading as an underscore laid over the glass and fighting the panel's own
  edge. A material can express being pressed into; it cannot express a drawn line.
- **The composer's actions are glyphs**, not the words "Stop" and "Send" — those two
  words cost a third of a phone's width between them. Both stay available: wanting to
  stop a turn while composing the next prompt is ordinary.

## Known gaps

- **The composer's glass stops above the home indicator.** The bar is a
  `safeAreaInset`, so its material ends at the safe area and a strip of paper — black
  in the dark — sits under it, which the transcript scrolls through. Seen in a still;
  the fix (letting the material run to the screen's edge while the field stays above
  the indicator) needs a scroll to verify, and nothing here can drive one.
- Deep-linking straight into a task before the task list has read its workflows
  leaves the step menu with nothing to offer, so it is hidden. The header then
  shows the agent and no step. Fixing it means the detail screen loading its own
  steps.
- The list, the transcript and the create screen have been looked at on an iPhone, and
  the create screen at the accessibility text sizes. **The connect screen has now been
  seen, in both appearances and against a live server** — it was the one screen whose
  text fields were still bordered rectangles rather than the app's well, which is fixed.
  **The archive view, the step menu and the session picker have not been seen at all.**
  Nor has anything on this screen been *driven*: the menus, the doors and the setup chat
  were built and never tapped, because a simulator has no tap command and creating a
  task is a write against someone's server.
