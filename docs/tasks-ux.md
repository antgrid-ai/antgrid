# Tasks — interaction design

Companion to `docs/tasks-and-integrations-plan.md`, which owns the data model
and sync. This file owns what the user sees and does, on both surfaces.

Out of scope by decision: push/email notification of any kind, and any Handler
mapping.

## The one thing that must not be lost

Every issue tracker already has a list, labels, a status and a detail page. The
only reason to build this inside Antgrid is that a task here can **become a
running agent session with an isolated worktree** — and that the list can show
which tasks are running *right now*, across machines.

So the design rule that outranks the rest: **the run is first-class everywhere.**
A "Running" view sits beside "Mine". A live run shows on the row, not just in the
detail. "Start session" is a button in the detail header, never a menu item. If a
screen could be screenshotted and mistaken for GitHub Issues, it is wrong.

## Personas

| Persona | Where | Wants | Fails if |
|---|---|---|---|
| **Maintainer** (dogfood: Bharath) | Desktop | Triage everything, assign, start runs, keyboard-only | Density is low, or triage needs a mouse |
| **Solo dev** | Desktop | File it, run it, close it | Assignment ceremony at n=1 — "assign to me" is busywork |
| **Contributor** | Desktop | "What's mine, what do I start next" | Buried under everyone else's work |
| **Team lead** | Any | "What is everyone's agent doing right now" | The Running view is not account-wide |
| **Triager on a phone** | Mobile | Read, re-prioritize, assign, comment, maybe start a run | It is **silent** — a run stalls on a permission and nothing says so |
| **Reviewer** | Desktop/Web | What did the agent do for this task | Runs show a session name and a start time, and no outcome |
| **The agent** | — | A brief it can act on | Fed a 10k-char issue thread verbatim |
| **External GitHub reporter** | GitHub only | Their issue keeps working | Our edits are invisible or mangled there |

Two of these are usually forgotten and both matter here. **The agent is a
persona**: the rendered prompt is a UI surface with a quality bar, and it is the
one the product's value actually flows through — and, once import ships, the one
place a stranger's text becomes an instruction (see Start session). **The external
reporter never opens Antgrid**: everything we write back must read naturally in
GitHub, which is what makes "no Antgrid-only status vocabulary leaking into issue
bodies" a design rule and not just a data one.

Two honest notes on the rest. **The reviewer is currently the worst-served
persona** — the Runs block is the reason they came and, until `TaskRun` gained
`branch`/`prUrl`, it showed them a session name and a start time; tapping a run
opens a session that needs *that machine's* bridge online, so reviewing a
teammate's run on a teammate's laptop gives nothing at all. And **the external
reporter's best outcome under the current rules is that we left no trace**, which
makes them closer to a constraint than a persona; whether they get a run-outcome
comment is the open scope decision recorded in the plan.

## Information architecture

Tasks are account-scoped; the app is project-focused. That tension resolves into
**two entry points over one list widget**, never two lists:

1. **Account-level Tasks** — the flat cross-machine, cross-project view. This is
   primary. It follows the precedent already set by the Recent list and the
   session search popup, which `app/CLAUDE.md` calls "the one flat view spanning
   machines and projects."
2. **Project-scoped Tasks** — the same list pre-filtered to the focused project,
   for heads-down work.

**Where each one lives — this is not settled by the IA and needs deciding first.**

*Account-level* has no home today. `WorkspaceView` is project-scoped by
construction (it lives inside `WorkspacePanel`, driven by the focused project),
`lib/screens/` has no account-level list screen, and `AbApp` is a home-only
`MaterialApp` with no routes — so "add a route" is not available either. The
precedent this view should follow is the one `app/CLAUDE.md` sets for session
search: *"a POPUP, not a filter over anything on screen… it answers into its own
`OverlayPortal` from any route."* That is already the shape of a flat view
spanning machines and projects in this product. Use the mechanism, not just the
concept.

*Project-scoped* means adding to `WorkspaceView`, which has two separate hazards:

> **1. The enum is persisted as a raw ordinal.** `workspace_shell.dart` restores
> `prefs.workspaceViewIndex` by index and its own comment records that removing
> "Services" once shifted every later view down with no migration. Append `tasks`
> at the END of `enum WorkspaceView { preview, files, git, terminals, handler }`.
>
> **2. Appending is ordinal-safe and still breaks the phone.**
> `mobile_bottom_nav.dart` iterates `WorkspaceView.values` into `Expanded` slots,
> and argues against a sixth item three times in its own comments — the drawer
> button is deliberately outside the `Expanded` tabs so it *"must not read as a
> sixth tab"*, and *"'Terminals' already runs close to its slot at the default
> text scale and past it at any larger one"* with five. A sixth ellipsizes labels
> on every phone, today.
>
> **So: tasks is not a bottom-nav tab on mobile.** It is reached the way the
> account-level view is reached — from the drawer or the top bar. On desktop it
> can be a `WorkspaceView`; `workspace_menu_button.dart` and the two exhaustive
> switches in `workspace_tab_bar.dart` (label + icon per view) are the other call
> sites that must change with it.

## Views

Named scopes as the primary control, filters underneath. Not a filter builder —
a maintainer triaging 200 issues wants one keystroke, not a query.

| View | Contents | Persona |
|---|---|---|
| **Mine** | `assigneeUserId` is me, not done | Contributor |
| **Running** | Has a live `TaskRun` | Everyone — this is the differentiator |
| **Unassigned** | Open, no assignee of either kind | Maintainer (the triage queue) |
| **All open** | Everything not done/cancelled | Maintainer |
| **Done** | Recently closed, newest first | Reviewer |

**Landing view is inferred, not fixed.** If the user has any open assigned task →
Mine. Otherwise → All open. Showing a brand-new user an empty "Mine" as their
first impression of the feature is the single easiest way to make it feel dead.

Filters compose under the scope as toggle chips (`AbChip.toggle` exists):
status, label, assignee, project. Multiple labels are **AND**, matching GitHub,
because that is what anyone who has filtered issues expects.

The active scope + filters must be nav-serializable (`navigation/nav_serialization.dart`)
so a view is deep-linkable and survives restart. On web that falls out of the URL
for free; in the app it is deliberate work.

## Status

Five states, and the vocabulary is ours, not GitHub's:

`open` → `in_progress` → `blocked` → `done` | `cancelled`

Tone mapping via `AbStatusTone`:

| Status | Tone | Note |
|---|---|---|
| `open` | `neutral` | |
| `in_progress` | `info` | the accent |
| `blocked` | `warning` | |
| `done` | `success` | |
| `cancelled` | `disabled` | |

`success` for `done` is correct here and does **not** violate the rule in
`ab_status_tone.dart`. That rule is about an *agent at rest* — "an agent that
finished a turn is not the same claim as an operation that succeeded" — and it
keeps dormant sessions from wearing green checks. A task marked done is a genuine
completion claim made by a person or accepted from one, so it earns `success`.

**Two status systems must never share a shape.** A row can carry both a task
status and a live agent status, and painting both as dots is how the row becomes
unreadable:

- **Task status → a labeled pill.** Persistent, user-owned.
- **Agent liveness → a dot** (`AbStatusDot`, pulsing for `working`). Ephemeral,
  machine-owned, present only while a run is live.

> **`AbStatusPill` cannot be that pill — a new widget is needed.** It takes
> `AbAgentStatus` (`idle|thinking|running|attention|error`), not a tone, and hard-
> wires the agent palette; it cannot render `neutral`, `success` or `disabled` at
> all. Worse, **it already contains a dot, and that dot pulses** for
> `thinking`/`running` — so using it here puts a pulsing task-status pill next to
> the pulsing agent-liveness dot, which is precisely the failure this section
> exists to prevent. `AbStatusTone` also documents that `disabled` is for
> dots/glyphs only and needs `textMuted` explicitly if rendered as readable text,
> which a labeled `cancelled` pill is.
>
> `AbStateChip` is the closest existing shape (`icon`, `label`, `tone`, `active`)
> but its own doc comment scopes it to *chrome that opens the surface where the
> state is changed*, sized to align with toolbar buttons — not a row-scale badge.
> Build `AbTaskStatusPill` against `AbStatusTone`, with no dot.

## Labels

Rendered from the stored GitHub hex, which is chosen for a light background we
do not have. Never use it as a fill.

**Rule:** the label color is a **dot or a 2px leading rule** on a neutral chip;
the text takes the normal foreground token. If a tinted chip is wanted, use the
hue at low alpha over the panel token and compute the foreground from relative
luminance (WCAG AA against the *resulting* surface, not against the raw hex).
Pure white and near-black label colors are common in the wild and both must
survive this.

`AbChip` applies its `color` to the **text**, so the neutral-chip-plus-colour-dot
rule above is not what `AbChip.label` does today. This needs a small new chip (or
a variant), not a call site.

Interaction:
- Click a label chip → adds it to the current filter. Nothing else. A chip that
  navigates somewhere surprising is the most common label-UI mistake.
- Label editing is a multi-select popover with a filter field, not a separate
  page.
- Creating a label inline from that popover is allowed; for a linked project with
  `pushEnabled` it writes to GitHub like any other edit — which means **a label
  name is user text that reaches a public repo with no consent moment of its own**.
  Worth a beat of thought before typing `area/acme-corp-migration`.

> **`AbMenu` cannot do this and neither can `AbSearchField` inside it.**
> `AbMenuEntry` has exactly two subclasses; `AbMenuItem` is
> `{label, onTap, value, icon, shortcut, danger}` with **no `selected`, no
> `checked`, no `trailing` and no arbitrary child**, and `showAbMenu` pops the
> route with the item's value on first selection — the opposite of multi-select.
> This is the largest hidden cost in this document: three of the keyboard
> shortcuts below open a surface that does not exist.
>
> **And it must be two surfaces, not one responsive widget.** `app/CLAUDE.md`
> rules out exactly this pattern on mobile, for exactly this reason: *"a phone has
> no row to spare for a permanent text box, and an anchored popup loses most of
> itself to the keyboard. A dialog ROUTE, not an overlay, so system back closes
> it."* `AbMenu` is a 240px route popup with no keyboard-inset handling. Follow
> the session-search precedent — `Dialog.fullscreen` on mobile, anchored popover
> on desktop, sharing only the results list.

## The list row

Dense and scannable — the row is where the maintainer persona lives.

```
● ANT-14  Fix flaky push-deliver test   [relay] [bug]   ◐BM  ⟳ claude   relay
│  │      │                             │               │    │          └ project (mono, hidden when scoped)
│  │      │                             │               │    └ live run: agent mark + pulsing dot
│  │      │                             │               └ assignee (one avatar; "+N" only for extra GitHub assignees)
│  │      │                             └ labels (max 2 + "+N")
│  │      └ title (sans — chrome)
│  └ number (mono — data)
└ task status pill
```

Font split follows the standing rule: number, project and branch are **mono**;
title and label names are **sans**.

**`attention` outranks everything else on the row.** When a run is blocked on a
permission or a question, the row says so — a warning-toned mark in the run slot,
not a generic pulse. An agent waiting on you, visible from the list without
opening anything, is the single most valuable thing this list can show, and it is
the state most likely to be sitting unnoticed.

Built from `AbListRow` (`density`, `selected`, `divider` all exist). Do not
hand-roll a row. Note that `actions` is **not** usable here: it is
`List<AbRowAction>`, a typed descriptor of icon buttons only, and `AbListRow`
asserts `actions == null || trailing == null`. The meta cluster (labels, avatars,
agent mark, project) goes in `trailing`, which means the row has meta **or** row
actions, never both — fine, because row actions live in the long-press sheet.

**Width is the real constraint, and the seven-column row does not fit.** The
context panel that holds a project-scoped view is half the window by default and
can be dragged to a fifth of it; on a 1440px window that is ~700px before the
drawer, ~290px at the minimum. A master–detail split inside that leaves roughly
300px of list. So:

- **In the four scoped views, lead with a dot, not the labeled pill.** Status is
  near-redundant in each of them — Mine excludes done, Unassigned is open-only,
  Done is done-only, Running is in-progress by definition. That recovers ~80px
  exactly where the list is narrowest.
- **Keep the labeled pill in All open and in the detail header**, where the
  status is actually carrying information.
- On tablets the panel starts hidden by default (`contextHidden` for mobile
  platforms, because splitting it leaves the terminal unusably narrow), so the
  account-level surface is the primary one there.

**Mobile** drops to two lines — title on the first, meta on the second — and
sheds the project column when the view is already project-scoped. Labels degrade
to a single chip plus a count.

**Row actions are a long-press `AbAdaptiveSheet`, not a swipe.** Swipe-to-act
would mean `Dismissible`, whose look is Material and whose gesture fights the
existing mobile page-swipe between agent and workspace. The adaptive sheet
already exists and already matches.

## Detail view

**Desktop: master–detail split**, not a route push. The list keeps focus, `j`/`k`
moves through it, and the detail follows. This matches the resizable three-zone
idiom and is what makes keyboard triage fast. A route push would cost a
navigation round trip per task.

**Mobile: a route push** from the row, with system back.

Order of contents, which is deliberately not GitHub's:

1. **Header** — number, title (inline-editable), status pill, and the **Start
   session** button as the primary action.
2. **Attributes row** — assignee, labels, project, all inline-editable.
   **Assignee is single-select and replaces**, unlike labels: the plan stores one
   assignee and never pushes it to GitHub. That second half is what makes the
   simpler control honest — changing the assignee here cannot unassign anyone in a
   real repo, so it needs no confirmation and no deliberate-removal ceremony.
   An assignee imported from GitHub with no Antgrid account renders as a login
   chip with a provider mark and is **read-only**; picking a member replaces it.

   **Where the issue has more than one GitHub assignee, say so.** The extra
   logins live in `remoteSnapshot`, not in a column, so the sheet shows the stored
   assignee plus a muted *and 2 others on GitHub* that links out. Showing one
   avatar and implying it is the whole picture is the lie this control could
   easily tell; a `+n` that goes nowhere is nearly as bad.
3. **Runs** — every `TaskRun`: agent mark, session name, branch (`AbBranchPill`
   exists), live status, start/end, and the **outcome** — PR link and
   `resultSummary` where they exist. Tapping one opens that session; that needs
   the run's own machine online, so the outcome fields must stand alone for a
   reviewer looking at someone else's run. **This block is above the body**,
   because it is the thing no other tracker can show and the thing a reviewer came
   for. A block that shows only a name and a timestamp does not earn that
   position.
4. **Body** — markdown (`markdown_preview.dart` exists).
5. **Comments / activity** — merged stream, newest last. On a task linked to
   GitHub, the composer carries a **stays in Antgrid** mark: comments are
   inbound-only in v1 (see the plan), so a reply typed here never reaches the
   issue. Put it on the composer, not under the sent comment — the point is to be
   read before typing, not after.
6. **Metadata** — source, GitHub link, created/updated, sync state.

**Publishing to GitHub is offered twice: on the create form, and afterwards in
the detail overflow.**

*On the create form* — a **Create on GitHub too** toggle with the destination
repo named beside it. It appears only when the selected project has an enabled
repo, and its starting position comes from that repo's default (see below). The
form is the confirmation: the title and body are on screen, being typed. Do not
add a second sheet on submit — a confirmation of a confirmation is a thing people
learn to click through, and it teaches them to click through the one that matters.

**The ON state carries weight; the OFF state does not.** A pre-checked switch and
one quiet line of grey text is the weakest available signal on the
highest-consequence control on the form — especially with no second sheet behind
it. Asymmetry is the whole trick: when ON, the row reads as a live warning with
the repo named in it — *"Will be created in `antgrid/antgrid` — public"* — using
`AbSwitch`'s `tone`. When OFF it can be as quiet as you like.

**Changing the project must not silently arm the toggle.** The toggle's presence
and position both derive from the selected project, and a preselected repo follows
when there is exactly one. Compose those and you get the accident this whole
design is meant to prevent: a user starts a private note, types a customer name
into the body, *then* picks a project — and a switch they never touched moves to
ON for a repo they never chose. A control that changes state underneath
already-typed text is exactly the control people stop seeing. So: when the project
selector changes, re-derive the toggle **and** announce it visibly (brief
highlight, repo named) — or refuse to auto-enable at all once the body is
non-empty.

*Afterwards* — for an unlinked task, the detail overflow offers *Publish to
GitHub*, opening a confirm sheet with the same three facts: repo (a picker, no
default, when the project has several), exact title and body, public-if-public.
This is the path for a note that started private and is now ready to share. It is
absent — not greyed — when there is no repo to publish to.

**Never a primary button.** The primary action on a task is **Start session**;
publishing is not what this product is for. And there is no bulk "publish
selected" in the list — it is the one shape with no per-task moment where the
user sees what is going out.

Once linked, both entries disappear and the metadata block shows the issue link
plus *Unlink* — which stops syncing and leaves the issue alone.

*Unlink puts the task back in the publishable state, and that is a trap worth
labelling.* Re-publishing an unlinked task creates a **second** issue; the first
one still exists and is still public. So the overflow item reappears after unlink
and its copy must say so — *"Publish to GitHub (creates a new issue; #412 stays
where it is)"* — rather than reading like a way to restore the old link.

**The project default.** Repo settings carry *Create new tasks on GitHub by
default*, off on install. It sets where the create-form toggle starts, nothing
else — every task still shows its own switch, and flipping it for one task does
not change the project. Show the current default as plain text near the toggle
("on by default for `antgrid/antgrid`") so the pre-checked state reads as a
setting rather than something the form decided on its own.

## Editing

**Inline over modal.** Title, status, assignee and labels edit in place; only the
body opens a larger editor. Every extra dialog is a tax paid on every triage
action.

**Optimistic with rollback.** Sync is asynchronous by design (outbox + drain), so
an edit must land in the UI immediately and revert visibly if the write fails.
Never block a field on a GitHub round trip.

*"Revert visibly" needs a design, not just a promise.* A silent snap-back is
indistinguishable from a mis-tap, and the window here is long — an edit sits in
the outbox through retries, rate-limit backoff and `Retry-After` waits. Three
states, not one: **pending** (a small provider-mark variant on the field, so the
user knows it has not reached GitHub yet), **reverted** (the old value returns
*with* a one-line reason and a retry affordance), and **conflict** (below).

**Provenance is shown, not assumed.** A field that also writes to GitHub carries
a small provider mark. The user should never be surprised that renaming a task
renamed a public issue.

**Conflicts get a real UI.** When the drain records `syncState='conflict'`, the
detail shows an inline banner with both values and two buttons — *Keep mine* /
*Take theirs*. This is the visible half of the merge policy; without it the
plan's "remote wins but we preserve yours" promise is invisible and therefore
false. (The losing value lives in `Task.localConflict` — it had no storage until
the plan gained that column, which is what made the promise hollow.)

> `AbInlineBanner` is `{text: String, color, trailing: Widget?}` — one line of
> text and one trailing widget. Two buttons fit in a `Row` as `trailing`; **two
> values do not fit in a `String`.** Another new widget — for the two-value
> conflict banner specifically. The launch sheet's single-message-plus-retry
> case fits the existing widget as-is, and phase 3c uses it unchanged.

**What shipped is a section, not a banner** — `Unsettled changes`, between
Source and Description in the detail sheet, one bordered card per conflicted
field with the two values **stacked** (a description is the field most likely to
collide and the least readable in half a phone's width) and a `Keep mine` /
`Keep GitHub's` pair per card. So the two-value banner in the new-widget table
below was never built; the need it names was real and the shape was wrong. Three
things the spec above did not anticipate:

- **Per field, not per task.** A merge can lose the title and the description in
  one delivery, and one pair of buttons cannot answer for both.
- **The dropped labels get an acknowledgement, not a choice.** One side removing
  a label the other still had has one honest outcome, so that card offers `Got
  it` and nothing else. It also never sets `syncState = 'conflict'`, so the
  section can appear on a task the badge calls synced.
- **A conflicted status is shown in GitHub's words**, not as a status pill. It
  is stored in provider space because that is where the merge compares it, and
  `open` covers `open`, `in_progress` and `blocked` — a pill would be a guess
  presented as the value being chosen between.

## Start session — the flow that matters

Primary action on the detail. Opens a small sheet, pre-filled and **editable**:

- **Machine** — **not shipped in phase 3c, and it cannot be until the wire
  carries it.** `runTargetDeviceId` and `runTargetProjectId` exist only in
  `web/prisma/schema.prisma`: `taskJson` (`web/src/routes/tasks.ts`) never emits
  them and the app's `Task` has no field for them, so there is nothing to default
  from. A task's `projectId` is an ACCOUNT uuid and the app's `AbProject` ids are
  a different namespace with no route between them, so a task cannot resolve its
  own local project either. The sheet therefore launches into the project the
  user currently has open and **says which one** rather than leaving it to be
  inferred. A real picker needs those two fields in `taskJson` first, and then
  the rule below: offline machines listed and disabled with the reason, never
  hidden.
- **Agent** and **mode** — from `agentCatalogProvider`; the existing rules apply
  (an agent nothing has described renders as unknown and disabled, never as
  "not chat capable").
- **Isolation** — defaults to **worktree**. A task is exactly the case isolation
  exists for.
- **Base branch** — project default.
- **The prompt** — rendered from the task and shown in an editable multiline
  field.

> **There is no widget for this yet.** `AbComposer` cannot be pre-filled — its
> constructor is `{agentTag, attachments, onSend, onRemoveAttachment,
> placeholder}` with no `initialText` and no `controller`, its controller is
> private and created empty, and it is dead code (nothing in `lib/` mounts it; the
> live one is `widgets/transcript/composer/rich_composer.dart`). `AbTextField` has
> no `maxLines`/`minLines` either, so **the design system had no multiline text
> input at all** — which also meant "only the body opens a larger editor" under
> Editing had nothing behind it. `AbMultilineField` now exists and serves both;
> the launch sheet and `task_create_sheet.dart` are its two callers.

That last one is the important one. The user must see what the agent will be
told before it is told, and be able to fix it. Template:

```
Task ANT-14: Fix flaky push-deliver test

<body, bounded>

Repo: github.com/antgrid/antgrid    Base: development
Task: https://…/tasks/ANT-14
```

Bounded on purpose — a 10k-char issue thread pasted into a launch argv is a bad
brief and, in terminal mode, a bad command line. Truncate with a visible marker
and let the user edit.

**Bounding is about brief quality. Provenance is about trust, and it is a
separate rule.** Once GitHub import ships, an imported body was written by whoever
opened the issue — a stranger, on a public repo — and it is about to become the
opening instruction to an agent with shell access on the maintainer's real
repository. So:

- **An imported task cannot launch without the sheet being seen.** The `r`
  accelerator opens the sheet for `source != 'local'`; it does not start a run.
  Local tasks the user wrote themselves keep the one-key path.
  As of phase 3c this holds structurally rather than by rule: `TaskLauncher.start`
  has exactly one caller in the tree and it is the sheet's submit. Whoever adds
  the `r` accelerator must keep it that way — a second call site is how the
  bypass comes back.
- **The untrusted span is delimited and labelled** in the rendered prompt — marked
  as an issue body from an external reporter, and as data rather than
  instructions. Not a guarantee, but an unlabelled paste is strictly worse and
  costs nothing.
- **Provenance shows on the row and in the sheet**, from `source` and the task's
  own `externalProvider` / `externalUrl`.

`docs/tasks-and-integrations-plan.md` carries the full reasoning under *"A task
body is untrusted input to an agent."*

**Reusing `new_session_action.dart` is not verbatim.** Two things to get right
(its comments described a stale error contract when this was written; they were
corrected before phase 3c and now match the behaviour below):

- `startNewSession` reads roughly six global new-session form providers and ends
  with `leaveNewSession(ref)`, which assumes the New Session page. A task sheet
  either writes all that form state or duplicates the sequence — pick one
  deliberately.
- The error contract. `sessions_service.dart` fails the pending completer with
  `SessionOperationException` on `ok:false`, so **a coded refusal throws**; `null` only means `ok:true` with no session. Typed failures are
  deliberately allowed to escape to the composer — and a task sheet has no
  composer, so it must catch `SessionOperationException` and show the reason
  itself, plus `TimeoutException` for a dropped reply — and a generic arm besides,
  the way `session_delete_flow.dart` does, or a disposed service leaves the sheet
  on a spinner it never clears.
- It reads `sessionsServiceProvider`, a per-project façade that **throws** when
  the focused project is unresolved. A sheet launched from the account-level list
  may target a cold or remote project with nothing focused; use
  `warmServiceFor(container, entryId, …)`, which exists for exactly this window.

## Keyboard (desktop)

The product claims keyboard efficiency; a task list is where that is tested.

| Key | Action |
|---|---|
| `j` / `k` | Move selection |
| `Enter` | Open detail |
| `r` | Start session |
| `e` | Edit title |
| `s` / `a` / `l` | Status / assignee / labels popover (`l` multi-select; `s` and `a` replace) |
| `c` | New task |
| `/` | Filter within the view |
| `1`–`5` | Jump to view |
| `Esc` | Close detail / clear filter |

No collisions with what exists — `Ctrl/Cmd+K` (session search),
`Alt/Ctrl+ArrowRight`, the three `Escape` consumers and the terminal's
`Ctrl+V`/`Ctrl+C` interception all leave this set free. Four things still need
deciding:

- **Something has to focus the list.** Single-key shortcuts need the list to own
  keyboard focus, and it sits beside a live PTY that swallows keystrokes. There is
  no proposed key to *reach* the task list, and `Ctrl+K` is taken — without one,
  the whole table is unreachable by keyboard, which is the maintainer persona's
  stated failure mode.
- **`Escape` becomes the fourth consumer.** Define precedence explicitly rather
  than adding a fourth claimant to the same key.
- **`/` opens a filter field, and then `c`, `e`, `r`, `j`, `k` type into it.**
  State the exit: `Esc` in a non-empty filter clears it; `Esc` in an empty filter
  returns focus to the list.
- **`Enter` already works.** `AbListRow` binds `ActivateIntent` to `onTap`, so
  "Enter opens detail" falls out for free if `onTap` is the open action — which
  also means Space does. Decide whether that is wanted.

Hints render with `AbKbd` / `AbKbdGroup`.

> **Discoverability has no home.** `AbCmdBar` is *not* a command palette — it is a
> project shell-command runner (`AbCmd{name, state, last, onTap}`, a hardcoded
> `⌘R`) and it is not in the product: its only mount is the design gallery. The
> app has no command palette at all. A ten-key single-letter model needs an answer
> for how anyone finds these; a `?` overlay listing the table is the cheapest one.

## States

### Empty

Each one names the next action — `AbEmptyState` takes a title and supports an
action, and also has an `.error` constructor worth using below.

| View | Message | Action |
|---|---|---|
| Mine (empty) | "Nothing assigned to you" | *Browse unassigned* |
| All (no integration) | "No tasks yet" | *New task* / *Connect GitHub* |
| Running (empty) | "No agents are working a task right now" | *Browse open tasks* |
| Filtered to nothing | "No tasks match these filters" | *Clear filters* |

### Not empty — the ones that were missing

An empty state shown during a fetch is the exact dead first impression the
inferred landing view works to avoid, so these are not optional polish.

| State | When | Treatment |
|---|---|---|
| **Loading** | First paint, cold app | `AbLoading` with a message. Never an empty state. |
| **Network offline** | No route to web | Tasks arrive over HTTPS from web, *not* through the relay — so a phone on a plane has no list at all. `AbEmptyState.error` with a retry; cached list if one exists. |
| **Sync pending** | Edit in the outbox | Per-field pending mark (see Editing). |
| **Publishing** | `issue.create` enqueued, not yet posted | The metadata block says *Publishing…* — the task exists locally and the issue does not, for as long as the drain takes. Without this the mental model after pressing the button is "it's public now". |
| **Publish failed** | Token expired, repo archived, permission, rate limit | Named reason and a retry. This is the one failure where a silent revert is worst: the user believes something is public that is not, or vice versa. |
| **Target unavailable** | `runTargetDeviceId` points at a revoked device | Named on the row and in the detail — the plan promises this string and nothing rendered it. |
| **Attention** | A live run is blocked | Warning-toned run mark on the row (see The list row). |

**"Offline" means two different things and the UI must not conflate them.** The
task list works with every dev machine offline — that is a real property worth
showing. It does **not** work with the network offline. A task can be read and
edited whenever web is reachable; only *running* it needs a live bridge.

## Web surface

Web is not a second command centre. It is the **away-from-your-machine and
whole-account** view: read, triage, assign, edit, follow a run's history. It does
**not** stream agent output and does not pretend to.

> **These notes describe the `site-redesign` branch, not `development`.** On
> `development` — where this work branched from — `NavSection` does not exist
> (nav is hand-written `<a>` tags), `bg-panel`/`border-edge`/`text-muted` have
> zero occurrences, and `styles.css` still declares `themes: dark --default,
> light`. `data-theme="dark"` is pinned either way, so the light theme is
> unreachable and there is no visual bug — but an implementer on this branch
> following the bullets below edits symbols that are not there. Rebase onto the
> redesign before starting web, or re-derive these against whatever branch is
> current.

- Nav: on the redesign, extend `NavSection` in `layout.tsx` and add the `NAV`
  entry. Both halves, one commit.
- Idiom is set by `devices.tsx` / `team.tsx`: `card bg-panel border border-edge`,
  `table table-sm font-mono text-xs`, `text-muted`/`text-muted2`. Dark-only in
  practice — do not write `dark:` variants.
- HTMX suits inline editing well: a field posts and the server returns the
  re-rendered row, with no client state machine. But **this would be the first
  mutating HTMX in the codebase** — the entire web UI contains one `hx-get`, a
  login-status poll in `pending.tsx`, and no `hx-post`/`hx-put`/`hx-patch`
  anywhere. So "web is the cheaper surface" is a bet, not an established pattern,
  and the bet includes designing the error path (what swaps in when the PATCH
  500s), which HTMX does not give for free.
- **Web's Running view is stale-by-poll and must not pretend otherwise.** Run
  liveness comes from `WorkStatus` on the bridge, and web cannot originate a push.
  "Which tasks are running right now" is the feature's reason to exist, so state
  the refresh interval in the UI and show the last-updated time rather than
  implying live.
- **`antgrid://task/ANT-14` is rejected by the parser.** `nav_serialization.dart`
  refuses any host but `nav`, deliberately, as hardening. The spelling is
  `antgrid://nav/task/ANT-14`, and it is not a one-line fix: the grammar's targets
  are `local/<projectId>`, `remote/<machine>/<projectId>`, `agent/<id>`,
  `settings`, `devices`, and an account-level task has no project target — so it
  needs a new `WorkbenchSurface` member *and* a new null-target segment. Budget
  for parser work. Deep links go through `app_links` only, never a framework route
  (the `PlatformRouteGuard` note in `app/CLAUDE.md`).

## New icons

`ab_icons.dart` currently has `list` (`list_unordered`), `check`, `circle`,
`circleCheck`, and `account` — which is the natural **assignee** glyph, so only
*unassigned* is missing from that pair. There is no tag, filter, issue,
milestone or checklist glyph. Tasks needs constants added there for at least:
task/checklist, tag, filter, and unassigned — plus a `tasks` glyph for the
`WorkspaceView` switch in `workspace_tab_bar.dart` if the desktop tab lands. They
are Codicons via `AbIcon`, routed through that file by convention; **never** reach
for `Icons.*`.

## New widgets this needs

The real cost of this document, and it was invisible while four of these read as
"already exists". None is exotic; all are load-bearing.

| Widget | Why the existing one does not fit |
|---|---|
| **Task status pill** | `AbStatusPill` is agent-status-typed and carries its own pulsing dot |
| **Multi-select filterable popover** | `AbMenu` has no selected state and closes on first pick — and needs a separate mobile dialog route. **Labels only** now that assignee is single-select: status fits `AbMenu` as it stands, and assignee needs the *filterable* half but not the *multi-select* half, so it can be the same widget with `single: true` rather than a third control |
| **Multiline text field** | `AbTextField` has no `maxLines`; `AbComposer` cannot be pre-filled and is dead code |
| **Two-value conflict banner** | `AbInlineBanner` takes one `String` |
| **Label chip with a colour dot** | `AbChip` colours the text, not a leading mark |

## What to build first

The list and the detail on the app, against local (non-GitHub) tasks, with Start
session wired. That combination is dogfoodable on day one, proves the only claim
that differentiates the feature, and needs none of the sync machinery. Labels ship
with the list; a triage view without them is not a triage view.

**Build the widget table above before the screens**, not alongside them — four of
the five are on the critical path for the list row and the detail, and discovering
them one at a time turns a screen into a widget project.

Web follows after, not immediately after: it is a second full implementation
whose stated job (away-from-your-machine, whole-account) overlaps heavily with the
phone, and its cheapness rests on an HTMX mutation pattern that does not exist
yet. A read-only page is a reasonable v1 for it.

**Mobile has one unresolved placement.** The primary action — *Start session* —
sits in the detail header, which is the hardest place to reach one-handed on a
route pushed from a mid-screen tap. The no-FAB rule does not forbid a
bottom-anchored action bar; decide before the detail is built.
