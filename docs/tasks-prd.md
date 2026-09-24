# Tasks — product requirements

Status: draft for review. Extracted from `docs/tasks-and-integrations-plan.md`
(data model and sync) and `docs/tasks-ux.md` (interaction design). Those two own
the *how*; this file owns the *what* and *why*, and is the document to argue
with before engineering starts.

Target for v1: dogfooded on `antgrid/antgrid`, GitHub Issues as the only
integration, built so Linear and Jira are a second adapter rather than a rewrite.

---

## 1. The problem

Antgrid is a command centre for coding agents. Today it can run an agent, watch
it, and control it from a phone — but it has no answer to *what should the agent
work on next*. That question lives in GitHub Issues, in a Linear board, or in
someone's head, and the round trip between "here is the work" and "an agent is
doing the work" is entirely manual: read the issue, open Antgrid, create a
session, retype the brief.

Two consequences, and the second is the expensive one:

- **The work list and the work are in different products.** Nobody can look at
  one screen and see both what needs doing and what is being done.
- **Nothing shows what agents are doing across machines.** A team lead with three
  developers running agents on three laptops has no view of it. Neither does a
  developer with a desktop and a laptop. This is the gap no issue tracker can
  close, because no issue tracker knows a session exists.

### Why now

The pieces this depends on already exist and are stable: isolated worktree
sessions, an initial-prompt path into a spawning agent, per-session live status,
and an account model with devices. Tasks is the layer that connects work items to
that machinery. It is also the last major surface before v1 that changes what the
product *is* rather than how well it does what it already does.

---

## 2. What we are building

A task list, owned by your Antgrid account, that syncs with GitHub Issues — where
**picking a task starts an agent session on an isolated checkout**, and the list
shows which tasks are running right now, on which machine, and which ones are
stuck waiting for you.

The one-line test, applied to every screen and every phase:

> **If a screen could be screenshotted and mistaken for GitHub Issues, it is
> wrong.** If a phase does not move a task closer to a running session, it is not
> v1.

### What it is not

It is not a better issue tracker. We are not competing on custom fields,
workflows, roadmaps, or sprints. GitHub keeps being the system of record for
anything public; Antgrid is where work becomes a running agent, and where you
watch that happen.

---

## 3. Who it is for

| Persona | Primary surface | What they need | We have failed them if |
|---|---|---|---|
| **Maintainer** (dogfood: Bharath) | Desktop | Triage a queue fast, assign, start runs, keyboard-only | Triage needs a mouse, or the list is too sparse to scan |
| **Solo dev** | Desktop | File it, run it, close it | Assignment ceremony at n=1 — "assign to me" is busywork |
| **Contributor** | Desktop | "What's mine, what do I start next" | Their work is buried under everyone else's |
| **Team lead** | Any | "What is everyone's agent doing right now" | The Running view is per-project instead of account-wide |
| **Triager on a phone** | Mobile | Read, re-prioritize, assign, comment, maybe start a run | It is silent — a run stalls on a permission and nothing says so |
| **Reviewer** | Desktop / web | "What did the agent actually do for this task" | A run shows a session name and a timestamp and no outcome |
| **The agent** | — | A brief it can act on | It is fed a 10k-character issue thread verbatim |
| **External GitHub reporter** | GitHub only | Their issue keeps working normally | Our edits are invisible there, or mangle their thread |

Two of these are easy to drop and both are load-bearing.

**The agent is a persona.** The rendered prompt is a UI surface with a quality
bar, and it is the surface the product's value actually flows through. It is also
— once import ships — the place a stranger's text becomes an instruction to
something holding a shell.

**The external reporter never opens Antgrid.** Anything we write back has to read
naturally in GitHub to someone who has never heard of us. That is what makes "no
Antgrid-only vocabulary leaking into issue bodies" a product rule, not a data
one. Under the current v1 rules their best outcome is that we left no trace at
all, which makes them closer to a constraint than a customer.

---

## 4. Goals and non-goals

### Goals

1. A task can become a running agent session on an isolated checkout in one
   interaction, with the brief visible and editable before it is sent.
2. The list answers "what is running right now, across every machine on this
   account" — including the tasks whose agent is blocked waiting on a human.
3. GitHub Issues arrive automatically and stay current, and edits made in Antgrid
   can reach GitHub without a copy-paste.
4. The task list is usable when every dev machine is offline. Only *running* a
   task requires a live machine.
5. A reviewer opening a finished task can see what the agent did — branch, PR,
   and a short outcome — without needing that machine online.
6. Nothing private becomes public without someone seeing it happen.

### Non-goals for v1

- **Notifications of any kind.** No push, no email. Assignment surfaces as a
  badge and a count on the next fetch. Doing it properly needs its own design and
  is deferred until everything else ships.
- **No mapping to the Handler backlog.** Tasks and the Handler's within-session
  instruction stack stay separate concepts with separate words in every UI
  string. They may marry later; there is no code path between them in v1.
- **No agent-facing task tools.** An agent cannot create or close its own tasks in
  v1. This is the shape the product should eventually have and it is deliberately
  not now.
- **No bulk publish.** No "select fifty tasks and push them to GitHub."
- **No per-task privacy.** Every member of an account can read and write every
  task on it. There is no "private to me."
- **Not a second issue tracker's feature set.** No milestones, no custom fields,
  no estimates, no cycles, no roadmap.

---

## 5. The core journey

The journey the whole feature exists to serve, in the order the user experiences
it:

1. **Work arrives.** Issues from a linked GitHub repo appear as tasks
   automatically. Tasks written directly in Antgrid sit in the same list.
2. **Triage.** The maintainer scans a dense list — number, title, labels,
   assignee, status — filters to a named view, assigns, sets priority, relabels.
   Keyboard-only on desktop.
3. **Start.** *Start session* is the primary action on a task. A sheet opens
   pre-filled: which machine, which agent, isolated worktree, base branch, and
   the rendered prompt — editable, with the task body bounded and clearly marked
   where it came from.
4. **Watch.** The task's row now shows a live run: agent mark, pulsing status,
   and the project. Across every machine on the account, from anywhere.
5. **Get unblocked.** When the agent stops for a permission or a question, the
   row says so in a warning tone. This is the highest-value pixel in the feature —
   an agent waiting on you, visible without opening anything.
6. **Review.** The task detail shows the run's outcome above the body: branch, PR
   link, and a short summary. A reviewer reads that without needing the runner's
   machine online.
7. **Close.** Marking the task done closes the GitHub issue, if it is linked.

Steps 1 and 7 are the integration. Steps 3 through 6 are the reason to build this
inside Antgrid rather than bookmarking GitHub.

---

## 6. Requirements

Priority means: **MUST** — v1 is broken without it. **SHOULD** — v1 is poor
without it. **LATER** — recorded deliberately, not in v1.

### 6.1 Task management

| ID | Requirement | Priority |
|---|---|---|
| T-1 | Tasks belong to an **account**, not a machine or a folder, so they survive a folder move and follow the user between machines. | MUST |
| T-2 | A task may optionally be bound to a **project** (a repo), and the list can be filtered to the focused project. | MUST |
| T-3 | Every task has a short, human-readable, permanent id (`ANT-14`) that appears in the UI and never changes — including when the task is later published to GitHub. | MUST |
| T-4 | A task carries title, body (markdown), status, labels, one assignee, and optionally a priority and a run target. | MUST |
| T-5 | Status is **Antgrid's own vocabulary**: `open`, `in progress`, `blocked`, `done`, `cancelled`. GitHub can only represent open and closed, which is exactly why we do not mirror its vocabulary. | MUST |
| T-6 | Labels are account-wide or repo-scoped, and are shaped to match GitHub's exactly so import and push are lossless. | MUST |
| T-7 | Tasks can be **reordered by drag** within a view, and the order persists. | SHOULD |
| T-8 | Deleting a task is reversible-feeling (soft) and stops all syncing for that task immediately. | MUST |
| T-9 | Comments on a task, from both Antgrid users and GitHub commenters, appear in one merged activity stream. | SHOULD |
| T-10 | Comments are **inbound-only in v1**: a GitHub comment appears in Antgrid, an Antgrid comment stays in Antgrid and is marked as such where it is typed. Pushing a comment is the second unretractable public verb after creating an issue and is deliberately out of v1 scope. | MUST |

### 6.2 Task → agent session (the differentiator)

| ID | Requirement | Priority |
|---|---|---|
| R-1 | *Start session* is the **primary action** on a task detail — a button in the header, never a menu item. | MUST |
| R-2 | Starting opens a sheet pre-filled with machine, agent, mode, isolation, base branch, and the rendered prompt — every field editable before launch. | MUST |
| R-3 | Isolation defaults to **worktree**. A task is exactly the case isolation exists for, and it also bounds the blast radius of a hostile issue body. | MUST |
| R-4 | The user sees **exactly what the agent will be told** before it is told, and can fix it. The task body is bounded with a visible truncation marker. | MUST |
| R-5 | A task can name a **run target** — which machine and which checkout should run it — so work can be queued for the desktop from a phone. | SHOULD |
| R-6 | Every run is recorded against the task: agent, session, branch, live status, start and end. | MUST |
| R-7 | A run records its **outcome** — PR link and a short summary — that stands alone for a reviewer whose colleague's laptop is offline. | MUST |
| R-8 | A live run shows **on the list row**, not only in the detail, and the Running view is account-wide across every machine. | MUST |
| R-9 | When a run is blocked on a permission or a question, the row shows it in a **warning tone**, distinct from a generic "busy" pulse. | MUST |
| R-10 | Starting a run moves the task to `in progress`; an agent needing attention moves it to `blocked`. Both are automatic, both defer to a human edit, and neither ever fires on a task that is already done or cancelled. | MUST |
| R-11 | An agent finishing a turn **never** closes a task. Agents declare completion optimistically; completion is proposed to the user, never applied. | MUST |
| R-12 | Offline machines appear in the machine picker **disabled with a reason**, never hidden. A revoked run target reads "target unavailable" on the row and in the detail. | SHOULD |

R-11 is a product decision that looks like an engineering detail. The available
"agent is done" signal cannot distinguish *finished the work* from *stopped
typing*, so auto-close would close tasks every time the user paused. A tracker
that closes things by itself, wrongly, is a tracker people stop trusting in about
a week.

### 6.3 GitHub integration

| ID | Requirement | Priority |
|---|---|---|
| G-1 | An account owner connects GitHub once, per account, and picks which repos sync. Connecting is a GitHub App install, not a personal token. | MUST |
| G-2 | Issues from an enabled repo import automatically and stay current as they change on GitHub. Pull requests are never imported as tasks. | MUST |
| G-3 | Import is **scoped per repo** — by label, milestone, or "assigned to an account member" — defaulted narrow. Pointed at a 500-issue repo with no filter, the list stops being *curated work* and becomes a mirror, and the Running view becomes a needle in a haystack we imported on purpose. | MUST |
| G-4 | Writing back to GitHub is **off by default, per repo, opt-in.** A team that imported issues as a private notes layer must not have that meaning changed underneath them by a later release. | MUST |
| G-5 | When both sides changed the same field, **remote wins and the user's edit is kept and shown**, with *Keep mine* / *Take theirs*. Silent data loss is never acceptable; a visible "changed in GitHub, your edit was kept aside" banner is. | MUST |
| G-6 | Any field that also writes to GitHub carries a **visible provider mark**. Nobody should be surprised that renaming a task renamed a public issue. | MUST |
| G-7 | An edit lands in the UI immediately and reverts **visibly, with a reason and a retry** if the write fails. The failure window is long — retries, rate-limit waits — so a silent snap-back is indistinguishable from a mis-tap. | MUST |
| G-8 | Antgrid's five statuses map to GitHub's open/closed on the way out, and coming back an unchanged GitHub `open` **never** overwrites a local `in progress`. | MUST |
| G-9 | Assignee is **imported and editable locally, and never written to GitHub in v1** — see 6.6. Where an issue has more than one GitHub assignee, the UI says so and links out. | MUST |
| G-10 | Unlinking a task stops syncing and leaves the GitHub issue untouched. It is the only reverse operation; there is no unpublish. | MUST |
| G-11 | Imported comments are **capped per issue**, with a deep link to GitHub for the rest, and the UI says plainly that it is a partial mirror. | MUST |
| G-12 | Linear and Jira are a second adapter, not a second implementation. No provider name appears anywhere above the integration seam except the registry and the icon. | LATER |

### 6.4 Publishing a local task to GitHub

This is the one irreversible action in the feature, and it gets its own section
because the failure is unrecoverable: deleting a GitHub issue is admin-only, and
the content is already in every watcher's inbox.

| ID | Requirement | Priority |
|---|---|---|
| P-1 | **Publishing is always an option the user chooses**, offered at creation and afterwards — never a consequence of some other action. A private note must not become a public issue because a background loop decided it should. | MUST |
| P-2 | Publication is never derived from a label, a status change, a project link, or "the project happens to have an integration." Only from a control the submitter saw. | MUST |
| P-3 | The create form carries a **Create on GitHub too** toggle with the destination repo named beside it. The form is the confirmation — the user is looking at the title and body they just typed. No second sheet. | MUST |
| P-4 | A per-project default may set **where the toggle starts**, never the outcome. Showing the default as plain text ("on by default for `antgrid/antgrid`") keeps a pre-checked switch reading as a setting rather than something the form decided. | MUST |
| P-5 | The **ON state carries visible weight** — the row reads as a live warning naming the repo and saying it is public if the repo is. The OFF state can be as quiet as you like. | MUST |
| P-6 | Changing the selected project must **not silently arm** the toggle. Re-derive it visibly, or refuse to auto-enable once the body is non-empty. A control that changes state underneath already-typed text is the control people stop seeing. | MUST |
| P-7 | An existing unlinked task offers *Publish to GitHub* with a confirm sheet naming the repo, the exact title and body, and the public-if-public line. | MUST |
| P-8 | Publishing is **never a primary button.** The primary action on a task is *Start session*. | MUST |
| P-9 | While an issue is being created the UI says *Publishing…* — the task exists and the issue does not yet, and the mental model after pressing the button must not be "it's public now." | MUST |
| P-10 | Re-publishing a previously unlinked task creates a **second** issue and the copy says so, naming the first one. | MUST |
| P-11 | Publishing a body that looks like it contains a secret (a pasted `.env` line, a cloud key) requires an explicit override. This is the one place in the product a pattern scan is worth its false-positive rate. | SHOULD |
| P-12 | **No bulk publish from a list selection.** It is the one shape with no per-task moment where the user sees what is going out, and it turns one mis-click into fifty public issues. | MUST |

### 6.5 Surfaces and interaction

| ID | Requirement | Priority |
|---|---|---|
| U-1 | **Both** the Flutter app and the web UI carry tasks. The app is primary; web is the away-from-your-machine, whole-account view. | MUST |
| U-2 | Two entry points over **one list**: an account-level flat view spanning machines and projects, and the same list pre-filtered to the focused project. Never two separate lists. | MUST |
| U-3 | Named views — **Mine, Running, Unassigned, All open, Done** — as the primary control, with filter chips underneath. A maintainer triaging 200 issues wants one keystroke, not a query builder. | MUST |
| U-4 | The landing view is **inferred**: Mine if the user has open assigned work, otherwise All open. Showing a brand-new user an empty "Mine" is the easiest way to make the feature feel dead. | MUST |
| U-5 | The row is dense and scannable, and shows task status, id, title, labels, assignee, live run, and project — degrading gracefully to two lines on mobile and to a status dot in narrow panels. | MUST |
| U-6 | Desktop detail is a **master–detail split**, not a route push, so `j`/`k` triage stays fast. Mobile is a route push with system back. | MUST |
| U-7 | Detail order puts **Runs above the body** — it is the thing no other tracker can show and the thing a reviewer came for. | MUST |
| U-8 | Title, status, assignee and labels edit **inline**; only the body opens a larger editor. Every extra dialog is a tax paid on every triage action. | MUST |
| U-9 | Full single-key keyboard triage on desktop, plus a discoverable way to see the key list and a defined way to move focus **to** the list from a live terminal. | SHOULD |
| U-10 | Views and filters are deep-linkable and survive restart. | SHOULD |
| U-11 | Web's Running view is **refreshed by polling and says so** — it shows the interval and a last-updated time rather than implying live. Run liveness comes from the machine, and web cannot be pushed to. | MUST |
| U-12 | Loading, network-offline, sync-pending, publishing, publish-failed and target-unavailable all have named treatments. An empty state shown during a fetch is the dead first impression U-4 exists to avoid. | MUST |
| U-13 | The two "offlines" are never conflated: **the list works with every dev machine offline**; it does not work with the network offline. Only *running* a task needs a live machine. | MUST |
| U-14 | Task status and live agent status **never share a shape** — status is a labelled pill, agent liveness is a dot. Two pulsing indicators on one row is how the row becomes unreadable. | MUST |
| U-15 | GitHub label colours are chosen for a light background we do not have. They render as a dot or a leading rule on a neutral chip, never as a fill. | MUST |

### 6.6 Assignment

| ID | Requirement | Priority |
|---|---|---|
| A-1 | Assignment is **required in v1** — both a human assignee and a run target — and they are separate things. Who owns the outcome is not the same question as which machine runs it. | MUST |
| A-2 | A task has **one** assignee: either an account member, or a read-only snapshot of a GitHub user who is not one. Never both. | MUST |
| A-3 | On import, prefer the GitHub assignee who maps to an account member. Where the issue has others, show *and 2 others on GitHub* with a link out. Lossy display is fine; pretending an issue has one assignee is not. | MUST |
| A-4 | **Assignee never writes back to GitHub in v1.** GitHub replaces the whole assignee list on every edit, so pushing our single assignee against a two-assignee issue would unassign someone in the customer's own repo. Assignment is inbound-and-local: imported, editable here for routing and filtering, not written back. | MUST |
| A-5 | Because of A-4, changing the assignee in Antgrid needs no confirmation and no removal ceremony — it cannot affect anyone's real repo. | MUST |
| A-6 | Assignment produces **no notification** in v1. It surfaces as a badge and a count on the next fetch. | MUST |
| A-7 | Assignee write-back, if ever wanted, is a phase of its own with read-modify-write against the live remote list. | LATER |

### 6.7 Trust, privacy and safety

These are product commitments, not implementation notes. Each one is cheap to
hold now and expensive or impossible to retrofit.

| ID | Requirement | Priority |
|---|---|---|
| S-1 | **A task body is untrusted input to an agent.** Once import ships, a body on a public repo was written by an anonymous stranger, and it becomes the opening instruction to something holding shell and filesystem access on a checkout of the maintainer's real repository, one click after triage. | MUST |
| S-2 | An **imported** task cannot launch without the prompt sheet being seen. The one-key accelerator opens the sheet; it does not start a run. Tasks the user wrote themselves keep the fast path. | MUST |
| S-3 | The untrusted span in a rendered prompt is **delimited and labelled** as an issue body from an external reporter — data, not instructions. Not a guarantee against a determined injection, but an unlabelled paste is strictly worse and costs the same. | MUST |
| S-4 | Provenance — where this task came from — shows on the row and in the sheet. | MUST |
| S-5 | A task body **never** reaches a non-interactive runner. Any future "run this automatically" path re-opens S-1 at full severity with nobody watching. | MUST |
| S-6 | **Agent output, diffs and transcripts are never written into a task body or comment.** Anything richer than a short outcome summary stays on the machine behind a session pointer. | MUST |
| S-7 | Customer-facing copy states plainly that **task titles, bodies and comments are stored on Antgrid's servers in plaintext and are visible to everyone on the account** — sitting next to, not replacing, the existing "your code and transcripts never leave your machine" claim. It is not called "metadata," because it is full body text and full comment threads. | MUST |
| S-8 | Connecting an integration, linking a repo, and enabling write-back are **owner-only**. Anyone can publish otherwise, and adding a teammate already grants them the entire task archive retroactively. | MUST |
| S-9 | Deleting an Antgrid account must actually delete task bodies and imported third-party data, and attempt to uninstall the GitHub App. | MUST |
| S-10 | A repo flipping from private to public is a **user-visible event**, because it retroactively exposes every issue published under the opposite assurance. | SHOULD |
| S-11 | **Inbound provider data can only ever land in the account that owns the installation it came from.** An uninstall followed by someone else installing on the same organization must not route that second party's issue bodies into the first account's tasks. Tenancy here is a schema property, not a code convention — see the engineering plan's webhook routing key. | MUST |

---

## 7. Explicitly out of v1

Recorded so nobody re-proposes them as gaps:

- Notifications — push, email, or otherwise.
- Any code path between tasks and the Handler's backlog.
- Agent-facing task tools (an agent creating or closing its own tasks).
- Bulk publish, or bulk anything that leaves the account.
- Per-task or per-member access control.
- Mirroring one task into two trackers, or linking a task to both an issue and a PR.
- An offline local mirror of the task list. Tasks are read over HTTPS; a cached
  list is a nice-to-have, a local database is not v1.
- Milestones, custom fields, estimates, cycles, roadmaps.

---

## 8. Decisions that need a product call

These are the reason this document exists. Each one is a business or policy
question that engineering cannot settle by being careful, and each has a deadline
before which the answer is cheap.

### D-1 — How much of "bidirectional" ships in v1
**Needed before:** the write-back phase. Everything up to it is identical either way.

Bidirectional is the target and is not in question. *Which writes ship first* is.
Walking the fields by what each buys a team dogfooding on their own repo:
pushing **title and body** is low value and a hazard (renaming a public issue
from a private tool); **status** is only ever the close/reopen bit; **labels** are
worth something if triage happens here; **assignee** and **user-authored
comments** are already cut (T-10). Note that the run-outcome comment in D-2 is a
different verb from the user comment T-10 cuts — different content, different
consent story — so cutting one does not settle the other.

The observation worth arguing with: *the highest-value write-back is the one we
banned, and the low-value ones are the fully-specified ones.* The alternative
shape is **import everything, write back only close/reopen plus one structured
run-outcome comment** — roughly a quarter of the sync cost.

The counter-argument is real and is why this is not simply applied: **a dashboard
you cannot act in gets abandoned.** If a task cannot be closed in Antgrid, people
close it in GitHub, and once they are in GitHub they stay. The minimum write set
is not zero.

### D-2 — Does a run outcome go back to GitHub?
**Needed before:** the same phase as D-1.

Today's trust rule forbids agent output leaving the machine. That rule should
forbid transcripts, diffs and agent output — it is less clear it should forbid a
branch name, a PR link and a diffstat, which are *already public the moment the
branch is pushed.* A structured, bounded run-outcome comment on the issue is
arguably the single most valuable thing this product could write to GitHub, and
the only thing an external reporter would actually want from us.

This is a positioning call as much as a privacy one: it is the difference between
Antgrid being invisible to a repo's community and being visibly useful to it.

### D-3 — Is Tasks free, or a Pro lever?
**Needed before:** the first public build. Do not gate it for dogfooding; do decide.

Note there is already an *implicit* gate — the app and bridge cannot obtain a
credential without an active subscription — so "free" needs deciding on purpose
rather than assuming the current behaviour.

### D-4 — Lawful basis and retention for third-party personal data
**Needed before:** the first non-dogfood customer, not after.

Importing issues means storing GitHub logins, avatars, and comment text authored
by **people who never signed up for Antgrid**, populated automatically. We need a
stated lawful basis and an answer to "delete my data" from someone who was merely
assigned an issue in a repo a customer connected.

### D-5 — The comment import cap
**Needed before:** the import phase. Now a value to pick, not a migration to plan
— the column (`commentImportCap`, per repo) is in the schema with a non-null
default.

Mirroring every comment on a busy repo is roughly ten hours of API budget for one
large repo and is the only table that grows without bound. Proposal: import the
most recent N per issue, deep-link the rest, and say plainly in the UI that it is
a partial mirror. **What is N, and is a partial thread acceptable product
behaviour?**

### D-6 — The default import scope filter
**Needed before:** the import phase. Also a value now, not a migration — the
columns (`importFilterKind`, one of `all | label | milestone |
assigned_to_member`, plus `importFilterValue`) are in the schema.

A repo with a few hundred open issues makes the account-wide "All open" view
unusable and buries the Running view. The engineering plan defaults the filter
**narrow**, so the Antgrid list is *curated work* rather than a mirror, with `all`
behind an explicit per-repo opt-in shown next to the issue count. **Which narrow
default ships — label, milestone, or assigned-to-member?**

### D-7 — Where Tasks lives in mobile navigation
**Needed before:** the app screens are built.

Tasks **cannot** be a sixth bottom-nav tab — five already crowd the bar at default
text scale and overflow at larger ones. It is reached from the drawer or the top
bar instead. Separately: the primary action *Start session* currently sits in the
detail header, which is the hardest place to reach one-handed on a pushed route.
A bottom-anchored action bar is permitted. **Decide both before the detail is
built.**

### D-8 — Is "every member reads every task" acceptable to say out loud?
**Needed before:** the trust copy ships.

There is no per-task privacy and no plan to add one, yet the entire publishing
design exists to protect private notes. Those two facts have to be stated
together in customer-facing copy, or the first person to notice will feel misled.
S-8 (owner-only integration control) is the minimum mitigation. **Is that enough,
or does v1 need a "personal" scope?**

---

## 9. Risks

| Risk | Consequence | Current mitigation |
|---|---|---|
| **A hostile issue body drives an agent** | A stranger's text becomes the opening instruction to a shell on the maintainer's repo, one click after triage | S-1 through S-5: sheet always seen for imported tasks, untrusted span labelled, worktree isolation by default. None of these is a guarantee — this risk is reduced, not closed |
| **An irreversible publish** | Private text becomes a public issue that cannot be deleted and is already in every watcher's inbox | The whole of §6.4. The residual risk is a user who clicks through a warning they have seen fifty times |
| **Plaintext bodies visible to every account member** | Adding a teammate retroactively grants them the full archive, including anything anyone treated as private | S-7 (say so plainly), S-8 (owner-only integration control), D-8 |
| **Third-party personal data with no retention story** | A compliance problem that grows with every synced repo and is worst at exactly the moment a large customer asks | D-4, unanswered |
| **First sync of a large repo** | A 5,000-issue repo is an ordinary day-one target and imports slowly, competing with interactive use | Bulk import is a distinct path; comment import capped (D-5); import scoped (D-6) |
| **GitHub's write budget** | ~8 sustained writes per minute across a whole account. A 50-repo org can exhaust it long before anything else breaks | Write-back opt-in per repo (G-4); assignee push cut entirely (A-4); the sync budget is a real reason to prefer the narrow shape in D-1 |
| **The reviewer stays under-served** | The persona most likely to justify a team seat gets a session name and a timestamp | R-7 (branch, PR, summary standing alone). This is why the Runs block sits above the body |
| **We build an issue tracker by accident** | Six months of feature parity work against products that have had a decade | The one-line test in §2, applied per phase: if it does not move a task toward a running session, it is not v1 |

---

## 10. Release milestones

Framed as what a user can do, not as what gets built. Each is genuinely usable on
its own; the numbering is a real dependency order.

**M1 — Tasks exist.** A local task list on the app: create, edit, label, assign,
filter by named view, on desktop and phone. No GitHub. *User-visible outcome: a
working task list that survives folder moves and follows you between machines.*

**M2 — Tasks run agents. This is the demo.** *Start session* from a task,
isolated worktree, prompt sheet, live run on the row, the Running view, `blocked`
surfacing when an agent needs you. *Everything before this is plumbing and
everything after it is reach.* M1 and M2 together are dogfoodable without GitHub
existing at all.

**M3 — GitHub issues arrive.** Connect the App, pick repos, issues import and
stay current, scoped and filtered. Read-only from GitHub's side — a mirror with
Antgrid's run machinery on top, which is already worth having. The untrusted-body
rules ship *here*, because this is the moment a stranger's text can reach an
agent.

**M4 — Edits reach GitHub.** Opt-in per repo. Edits to already-linked tasks
first — low blast radius — then publishing a local task as a new issue, with the
create-form toggle, the after-the-fact action, and the required explicit choice.
Publish is deliberately last: it depends on the write path being trustworthy, and
it is the step that can put private text in public. **Do not build it first
because it demos better.** D-1 and D-2 must be answered before this milestone
starts.

**M5 — Assignee import.** GitHub assignees resolve to account members where they
map, render read-only where they do not, and multi-assignee issues say so. Small,
because nothing is pushed. Can land alongside M3 rather than after M4.

**Later — Notifications.** Only after M1–M5 are dogfooded, and needing its own
design.

The web surface is built alongside M1 and M2 rather than as a milestone of its
own. A read-only web page is a defensible v1 for it: its stated job overlaps
heavily with the phone, and its cheapness rests on an interaction pattern that
does not exist in our web UI yet.

---

## 11. Success signals — *proposed, not extracted*

The source documents do not define metrics. These are a starting proposal to
argue with, and the first three matter more than any usage number, because they
test the product claim rather than engagement.

1. **Task-to-session conversion.** What share of tasks that reach `in progress`
   got there through *Start session* rather than a manual edit? If it is low, we
   built an issue tracker.
2. **Time from `blocked` to human response.** The point of surfacing a waiting
   agent on the row is that someone answers it faster. This is the number that
   proves the Running view earns its position.
3. **Dogfood displacement.** Do we stop opening GitHub Issues for
   `antgrid/antgrid` day to day? A binary, honest signal, and the one available
   first.
4. Share of accounts with an integration connected, once M3 ships.
5. Share of connected accounts that opt in to write-back, once M4 ships — a
   direct read on whether D-1 was answered correctly.

---

## Appendix: provenance

Everything in §§1–10 is extracted from, and traceable to, two engineering design
documents in this repo:

- `docs/tasks-and-integrations-plan.md` — data model, sync design, security
  analysis, build order, open items, and an appendix comparing the design against
  a shipped implementation of the same feature in another agent-workspace product.
- `docs/tasks-ux.md` — personas, information architecture, views, the list row,
  detail layout, editing, the start-session flow, keyboard model, states, the web
  surface, and the widget inventory the design implies.

§11 is **not** extracted. It is a proposal added at this layer and should be
treated as the least settled part of this document.

Where the two engineering documents record a decision as open, this document
records it as open too, in §8 — it does not resolve them by omission or by
picking the convenient reading.
