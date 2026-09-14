# Session Messaging — Feature Spec

> **v0.1 — supersedes `multi-machine-session.md`.**
> That spec built a *session that spans machines*. User interviews (Sept 9) found
> the machine was never the thing people wanted to join: they want **sessions to
> reach each other**, on one machine or several, across agents from different
> vendors. The machine becomes a transport detail. Six of the fourteen decisions
> in the old log are void as a result — see §3, which is the first thing to read
> if you know the old spec.

---

## 1. Summary

A session can **discover** the other agent sessions working on the same
repository, and **message** them directly. Two sessions on one machine talk
in-process. Two sessions on different machines talk over the existing E2E relay.
Neither the agents nor their tool surface can tell the difference; only the
transport does.

There is no lead, no membership, and no task lifecycle. Sessions are peers,
already exist, belong to whoever started them, and are addressed rather than
recruited.

The unit of work is a **message**. The unit of durable result is an **artifact**,
unchanged from the previous spec.

---

## 2. Problem

### 2.1 What the interviews found

Users would not manually link two sessions. Asked to describe what they wanted
instead, they described a session that *finds* the relevant one — "the session on
the build machine that's on this same bug" — and talks to it. The linking
ceremony was the objection, not the collaboration.

Two consequences the old design could not absorb:

1. **Same-machine is the common case, not a degenerate one.** Most of the time
   both sessions are on the desk in front of them. The old design routed
   everything through the relay via a carrier app, so the common case paid for
   machinery it did not need.
2. **The work is bugs and features, not only diagnosis.** D1 held that sessions
   establish ground truth and do not implement. The interviews describe
   implementation collaboration outright. D1 is void (§3).

### 2.2 The qualifying bar, revised

The old bar (simultaneity, locality, non-uniform access) existed to justify the
expense of standing up a resident agent on another machine. Nothing is stood up
any more — every participant is a session that already exists — so the bar goes
with it. The cost of a message is a message.

What survives is the *containment* bar: a session may be interrupted by another
session only within budget (§7.4), because an agent's turn is the scarce thing.

### 2.3 Non-goals

- **Cross-owner sessions.** Everything here assumes one account. Breaking it
  changes discovery, consent and the disclosure model together.
- **Foreign agents.** "Different vendors" means the agent CLIs Antgrid spawns and
  wraps (§9). An agent Antgrid did not spawn — a hosted service, a CI runner, a
  teammate's editor — is out of scope and is the trigger condition D3 named for
  reopening the A2A protocol question.
- **Shared state.** Sessions message; they do not share a working tree, a
  transcript, or a context. Two agents editing one checkout is a different
  feature with a different failure mode.
- **Broadcast.** Messages are addressed to one session. Fan-out is the sender
  looping, and the budget applies per pair.

---

## 3. Disposition of the previous decision log

The single most useful table for anyone who knows `multi-machine-session.md`.

| # | Decision | Status |
|---|---|---|
| D1 | Sessions establish ground truth; do not implement | **Void** — the interviews describe bug and feature collaboration. This was the spec's termination bar; §11 replaces it. |
| D2 | MCP as local API, custom bus as session model | **Carried.** Still exactly right, and now load-bearing for vendor reach (§9). |
| D3 | A2A data model, not protocol | **Amended.** Message / Artifact / Part carried. Task dropped with the lifecycle. Revisit trigger (a foreign agent) still armed and now closer. |
| D4 | Fixed envelope, open payload | **Carried.** |
| D4a | Envelope is routing metadata only; no `blocking` flag | **Carried, and load-bearing.** Its finding — agents over-declare urgency — is why interruption is a *verb* (`notify`) and not a flag (§7.1). |
| D4b | A2A field names adopted directly | **Carried.** |
| D4c | Bridge holds pending state durably, not the context window | **Amended** — the durable thing is the mailbox, not a pending-request record. Same reasoning: a context window is lost to compaction. |
| D4d | Phone out of the data path; desktop app in | **Carried.** |
| D4e | Lead is the sole human-facing agent | **Void.** Replaced by E7, which dissolves the problem rather than solving it. |
| D5 | Reference over value | **Carried.** |
| D6 | Lead-to-peer only | **Void.** Everything is peer-to-peer now; this was the constraint the bus was told not to preclude, and it does not. |
| D7 | The lead's desktop app carries the leg | **Amended** → E4. The *initiating* machine's app carries a remote leg; a local send has no carrier at all. |
| D8 | N concurrent app sessions per bridge | **Carried.** Still required: the phone and another machine's app attach at once. |
| D9 | The session spans machines; no new object | **Void.** Sessions do not span. They message. |
| D10 | A peer is always a session created for the purpose | **Void** — and its removal is the feature. Messaging a session that already exists is what the interviews asked for. |
| D11 | Deletion total, confirmed, or reconciled | **Void.** Nothing is created, so nothing needs deleting. A session is owned by the machine it runs on and ends when its own user ends it. |
| D12 | MCP tools injected per spawn from the bridge binary | **Carried, and now the roadmap** (§9). |
| D13 | Transitions acked and idempotent; messages lossy | **Amended** → E6. The delivery receipt survives; the task lifecycle does not. |
| D14 | No new screen: kebab, dialog, member tabs | **Amended** → still no new screen, but the surface is a directory and an inbox, not an add-machine dialog (§8). |

---

## 4. Data model

### 4.1 Objects

| Object | Purpose |
|---|---|
| **Session** | Unchanged and unextended. No `members[]`, no `memberOf`. A session does not know it is reachable; the bridge answers for it. |
| **Address** | `(machineId, projectId, sessionId)`. Already exists as `SessionMemberKey` / `SessionMemberRef` and already addresses a local session and a remote one identically. |
| **Directory entry** | One addressable session as another session sees it: address, generated title, branch, work status, last activity, and whether it can reply. Derived, never stored. Shape and sourcing in §5.5. |
| **Message** | One turn from one session to another. Carries a thread id. Lossy by design; see E6 for what is not. |
| **Thread** | A correlation id grouping a message and its replies. The whole of what remains of the task lifecycle, and the minimum that makes "which question is this answering?" answerable. |
| **Mailbox** | Per session, durable, holds `post` messages until read. |
| **Artifact** | Unchanged: a durable result held in session state, referenced by id, never fetched across machines (D5). |
| **Part** | Unchanged: text, file reference, or structured data. |

**Rule, carried forward unchanged:** anything that matters is an Artifact.
Messages are conversation and may be dropped.

### 4.2 What a thread is not

A thread has no state machine. It is not `pending`/`working`/`completed`; there
is nothing to observe and nothing to ack into a terminal state. A thread is open
for as long as either side keeps writing to it and is garbage after both stop.
This is deliberate — the previous spec's task lifecycle existed to let a *lead*
know whether delegated work had finished, and there is no delegation any more.

The cost is real and stated: **nobody can tell you whether the other agent
actually did the thing.** You have to ask it. That is what a peer relationship
costs and it is what the interviews chose.

### 4.3 Field ownership

Bridge-owned, never an agent parameter: the sender's address, timestamps, thread
id, the delivery receipt, and every budget counter. Agent-supplied: the
recipient's address, the body, the thread id when replying, and `summary`.

---

## 5. Discovery

### 5.1 The addressable set

**Sessions sharing a normalized git remote.** `normalizeRemoteUrl`
(`bridge/src/capability-card.ts:109`) already computes this key, already strips
credentials, and is already what the add-machine dialog matched on. A session may
address any session — local or remote — whose project resolves to the same key.

Three properties this buys:

- A managed worktree session and its parent-repo session are mutually
  addressable, though they hash to different project ids. Same-project scoping
  would have missed exactly that pair.
- The set is bounded by something meaningful rather than by an account, so the
  directory does not grow with the fleet.
- It fails closed on a project with no remote: no key, no peers, no directory.

A project with no git remote is not addressable and cannot address. Stated
plainly in the directory rather than shown as an empty list.

### 5.2 Only connected machines

The remote half of the directory is drawn from machines with a **live
control-plane session**. Not the account inventory, not a cached list.

This is not a limitation being accepted; it is the correct definition. The bridge
dies with its desktop app, so a machine nobody is at can neither answer nor be
answered. Listing it would offer a peer that cannot be reached.

### 5.3 The row, and what carries it

A directory row carries **OS, normalized remote and branch per project**, plus
the generated title, activity and work status of each session (§5.5). That
content is what the original design specified. What carries it is not.

**Shipped.** The card does **not** ride the projects advert. A machine answers
for its own sessions on demand, through the `machine.capability-card` RPC it
already served — widened with `repoKeys` (answer only about these
repositories) and `includeSessions` (attach the rows). `sessions` and
`sessionsTruncated` are additive keys, so a bridge predating them answers as it
always did, and a caller asking for neither sends a byte-identical request.

The delivery changed because **a bridge cannot dial another bridge.** There is
no bridge→app request direction anywhere in `bridge/src`; the plane is
app-initiated. So the remote half is filled by a **push, not a pull**, and the
desktop app — the only party holding sessions to more than one machine — is the
carrier:

- The app **peeks** at control-plane sessions that are already open, and never
  dials a machine to fill the directory. Eager connect-everywhere is capped for
  a reason (`kEagerControlPlaneCap`); a machine nobody has opened contributes
  nothing and is *named* as not asked rather than silently omitted.
- It asks each for a session-bearing card and pushes every answer down loopback
  as one `session-bus:remote-directory` control request. That verb is
  loopback-only, behind the host's bearer token, and unreachable from the relay
  — which is the point. `bus.setInboundHandler` accepts relay-origin frames from
  any account-trusted peer whenever the machine switch is on, so resolving this
  through an `AbMessage` arm instead would have let a phone forge directory rows.
- The bridge **mirrors, and never trusts.** Every row is re-validated on
  arrival; one that fails is dropped and counted alone rather than failing the
  push, because the push's error code is the one a carrier latches off on. A
  machine id carrying a control or format character is *refused*, not cleaned:
  `machineId` and `sessionId` together are the address, so a stripped id either
  resolves nowhere or resolves to a different machine.
- The mirror expires on its own after `REMOTE_ROWS_TTL_MS` without being asked
  again, and `list_sessions` reads memory. The read never blocks on the network,
  so a peer that went quiet costs the answer nothing but its own rows.

Because being pushed to is what proves a carrier exists, the app re-pushes on a
heartbeat even when nothing changed. There is no capability flag for this on
either hello: presence is `lastPushAt`, a fact, rather than a boolean that Zod
could strip in silence.

**No relay polling, no server-side index and no new disclosure.** The card
travels the same E2E control plane it always did; the relay still sees opaque
blobs and web still holds identity only (`deviceUuid`, `displayName`,
`platform`, `ed25519Pub`, `lastSeenAt`).

**`branch` is a ranking hint, never an identity.** Nothing is matched or routed
on it, so one a few minutes stale is fine, and it is deliberately not a sort key
on the answering side — that machine does not know which branch the asking agent
is on.

### 5.4 The directory is machine-level, not project-level

Repo-scoped addressing spans project ids on one machine, so the directory, the
route table and the budget counters belong to the host server rather than to a
project core. **This is the largest structural change in the rescope** and it
is not optional: leaving them in the project core makes a worktree session
unable to reach its own parent.

**Shipped.** One `SessionBusCoordinator` is owned by the host for the life of
the process, and `routes.json` moved to `<abDir>/session-bus/`. The transport
did not move with it: each outbound frame still leaves through the owning
project core, which is what keeps the machine's remote-access switch and the
per-device gates in front of it. The per-session stores stay under
`agents/<projectId>/session-bus/`, since the reach failure was an addressing
failure and nothing about those bytes had to move to fix it. The budget
counters are not a relocation at all — there is nothing on disk to move — so
they are built with the budget itself (§7.4).

### 5.5 Relevance: the bridge sorts, the agent judges

The addressable set answers *who could I talk to*. It does not answer *who should
I talk to*, and the bridge must not try: it is guessing with strictly less
context than the agent asking. Its job is to hand over a judgeable row and to
make a wrong guess cheap.

**The directory row.** Every field already exists:

| Field | Source |
|---|---|
| Generated title | `title-generate.ts` — a headless model over a transcript excerpt, prompted for "a title for the session's overall task: 3 to 6 words naming the task, not the wording", capped at 60 chars and re-resolved from hook posts as the session runs, so it tracks drift rather than freezing at the first message. |
| Branch | Capability card (§5.3). |
| Work status, last activity | The answering machine's session index, carried on the card (§5.3). |
| Can reply | Whether the agent declares an `mcp` profile (§9). |
| Address, labels | §4.1. |

A row therefore reads `fix/auth · Refresh expired OAuth tokens · running, 2m ago`,
which is judgeable. A row that reads only `antgrid-public-26` is not, and that is
the whole difference.

**Sorting is objective and is all the bridge does:** same branch above same repo;
running above idle above stopped; recently active first; can-reply above
receive-only. That is ordering, not a relevance score, and the line is deliberate.

**`post` is the relevance probe, and it is why none of this has to be accurate.**
Because a post does not interrupt (§7.1), an agent that is only half sure can ask
instead of inferring harder — *"chasing a 401 on token refresh on `fix/auth`,
same thing?"* costs the target no turn and no interruption. The agent does not
need to be right from the directory; it needs to be right enough to ask. This is
a second, unplanned reason the post/notify split earns its place.

**Explicitly not built: semantic matching over transcripts.** It requires content
shipped to a common point to be compared, which is the exact thing the E2E
posture exists to avoid; it is expensive; and it answers "are these texts
similar" when the question is "should these two agents talk", for which
similarity is a poor proxy.

**Prior art, and its measured limit.** Claude Code's `ListAgents` is the same
architecture — a flat unranked list, name is the address, the model judges — and
it is the right architecture. Its weakness is the row: the name is the checkout
directory, not the work, with a short ref appended only to break collisions.
Observed in practice on 2026-09-09, from inside a Claude Code session on this
repo: the list returned **149 rows**, and a search for a specific session by both
its name and its ref found neither. At that size a directory-name list cannot
locate a session whose identity is already known, let alone rank one by
relevance. Antgrid starts ahead on both axes — the candidate set is bounded to a
repo and to connected machines (3–15 rows, not 149), and the name already names
the task. Copy the architecture; do not copy the row.

### 5.6 A session can name itself

The directory answers "who can I address" and deliberately drops the asking
session's own row. Nothing else on the bus names the caller either: a delivery
names its SENDER, and a send result names the thread it opened. So an agent had
no way to say where it could be reached.

That is a hole in exactly one shape, and it is the shape delegation takes. A asks
B to have C report back to A. B can address C, and C can answer B — but nothing
can put A's address in front of C, because A cannot read it and B was only ever
told A's labels. The chain has to be relayed by hand through the middle session.

`antgrid_whoami` closes it: the caller's `machineId/projectId/sessionId` and the
title it is listed under. Two properties are load-bearing.

- **It is a separate read, not a field on the directory.** Listing sessions
  spawns git per row and is refused outright where there is no directory. A
  session must still be able to say who it is on a bridge that cannot say who
  anyone else is — an identity that is unavailable exactly when the network is
  broken is unavailable when it is needed.
- **It always spells the machine**, where a directory row for a local session
  omits it. A row is read on the machine it means, so the omission is correct
  there. This address is asked for in order to be given away: handed over with
  the machine dropped, it names the machine of whoever reads it, and the send
  that follows lands on a session nobody meant.

A machine with no relay identity has no first part to give. The answer says what
that costs rather than printing the remaining two thirds bare, which would be
copied off the machine and resolve against the reader's own.

---

## 6. Transport

### 6.1 The address chooses the path

One send verb. The bridge compares the target's `machineId` to its own:

**Local — same machine.** The host process holds every project core, so both
sessions' delivery queues are in-process. The message is handed straight to the
target's queue. **No relay, no carrier, no app, no encryption leg, no route
table, no retry.** It cannot fail for transport reasons, and it works with the
desktop app's relay connection down and with remote access off.

**Remote — another machine.** The existing path: the sending machine's desktop
app carries the leg to the target bridge, exactly as the lead's app did (D7),
because a bridge still cannot dial another bridge. The route table
(`route-store.ts`) already keyed `contextId → relay slot id` and already
learned routes from inbound traffic rather than from a role — generalizing it
still widened the row with a `projectId` (E9/§5.4: one machine-level table can
now hold a route for any project this host has open, and the row is the only
thing that says which project's stream a peer-role dispatch may use), which
bumped `ROUTE_STORE_VERSION` and discarded `routes.json` on upgrade.

### 6.2 Why the split is worth its cost

A local send that went through the relay would take a message between two
processes on one machine out to a server and back, would fail when the network
did, and would need a carrier app focused on the right project. Since same-machine
is the common case (§2.1), the common case would be the fragile one.

The cost is two code paths where there was one. Contained by making the split a
single decision at send time, with everything after it — wrapping, queueing,
turn-boundary injection, budgets — identical for both.

### 6.3 Symmetry requires remote access on both ends

The old design needed the switch on only at the recruited machine. Peers
initiating in both directions need it on at **both**. Default is off, so a fresh
pair of machines cannot message until a human turns it on at each — and that is
the correct place for that consent to live (§8.1).

Local messaging is unaffected and needs nothing.

---

## 7. Delivery

### 7.1 Two verbs, not one verb and a flag

- **`post`** — lands in the target's mailbox. Does not interrupt. Read when the
  target chooses.
- **`notify`** — submits a line into the target's session at its next turn
  boundary. Interrupts. Budgeted (§7.4).

The choice lives in the verb because D4a established that agent-declared urgency
is unreliable in a predictable direction: models over-declare. A `notify` costs
budget and a `post` does not, so the cost is on the axis the sender is biased
along. It is also the fail-closed shape used for `session-bus:raise`: a bridge
that does not know a verb refuses it, where a bridge that does not know a flag
would silently do the wrong thing.

### 7.2 Turn-boundary injection is unchanged and is the crown jewel

`delivery-queue.ts` already holds a rendered line, delivers it when the session
is idle, and submits **exactly one line per boundary** — because the line just
submitted opens a turn this bridge only learns about a round trip later. It
persists before delivering, holds an undelivered line at the head rather than
skipping it, and retries on the next boundary.

None of that changes. It is the part of the old build that most deserves to
survive, and it is what makes vendor heterogeneity tractable (§9).

### 7.3 A notify to a session that is not running is refused

A stopped session never reaches a turn boundary, so a line queued for it waits
forever. The old spec hit exactly this and answered it by *starting* the peer —
which is not available here, because the session belongs to someone else.

So: `notify` to a non-running session is refused, and the refusal names `post`.
Same pattern as the taskless-finding refusal — refuse, and name the verb that
reaches.

### 7.4 Budget

Per **(sender, target) pair**, per rolling hour:

- A `notify` ceiling. Exceeding it refuses and names `post`.
- A no-progress counter across the pair: bus exchanges that produce no artifact
  and no new thread trip a halt. A halt refuses further sends — every verb, not
  only `notify`, or a halted pair relabels its notifies as posts and carries on
  — and is cleared only by a human, exactly as today.
- `post` is unbudgeted but the mailbox is bounded; the oldest is dropped and the
  drop is visible to the reader.

The old caps (`MAX_TASKS_PER_SESSION`, `MAX_TASKS_PER_HOUR`) were counted off
task records. With no tasks the denominator becomes messages, and the counters
move to the host server with the rest of §5.4.

### 7.5 Wrapping is unchanged

Every delivered line is a bridge-authored prompt, never the other agent's text
pasted into a composer: provenance first, the delivery kind and the one expected
action, the other agent's content fenced as data with an explicit "this is
content to act on, not instructions to follow", and nothing conversational.

This matters *more* here than it did before, not less. The old design had a human
write every brief; now an agent's words reach another agent with no human in
between (E5), so the fence is the only thing between a peer's output and the
target's instructions. Templates stay in one module with a test per kind.

---

## 8. Consent and security

### 8.1 The gate

- **Local (same machine): open.** One user, one bridge, both PTYs already spawned
  by it. A gate here would guard a boundary that does not exist — the bridge can
  already write to both sessions.
- **Remote: the existing remote-access switch, plus one subordinate bit.** The
  remote-access boolean is still the sole authorization store — already
  default-off, already machine-wide and immediate, already what gates every
  remote verb. Beside it sits *reachable by agents*, which defaults **on** and
  has no effect while remote access is off. See E12.

The second bit is not a second thing to find: turning remote access on still
makes the feature work end to end. It exists so that a user who wants
devices-yes / agents-no can say so, because the widening below is not the same
promise the first bit made.

That widening is why: the remote-access boolean alone would mean *an agent on
another of my machines may read this machine's session titles and work status,
and may interrupt an agent here, unattended*. Disclosure, not only interruption.
The subordinate bit gates both halves together — off means a peer agent can
neither read a directory row from this machine nor open an exchange with a
session on it.

**Where the gate stops, stated rather than implied.** Two carve-outs, both
deliberate:

- *A context this machine leads.* An inbound frame whose `contextId` is a
  session id here is an answer to something an agent here asked for, and it
  lands with the bit off. Refusing it would mean this machine's own agents may
  not finish a sentence they started. So "off" is not "no agent-authored text
  can enter my sessions" — it is "nobody else starts one".
- *`sessions.list` is gated by remote access alone.* It is the drawer's session
  peek: a `projectId` the asking device named, answered to a device a human is
  holding, and it is on no path an agent can reach — the directory pump asks for
  the capability card, and the MCP tools read the mirror that card fills. Gating
  it on the subordinate bit would take the recent-sessions list off the user's
  own phone in exchange for closing nothing.

### 8.2 What an addressable session cannot do

- Read another session's transcript, files, or context.
- Start, stop, fork or configure another session.
- Reach another session's human (E7).
- Address a session outside its repo key, or on a machine that is not connected,
  or on a machine with remote access off — or with *reachable by agents* off,
  unless the context is one that machine leads (§8.1).
- Exceed its notify budget, or send at all once the pair is halted.

### 8.3 Content trust

A message body is agent-authored and is treated as hostile input at the
receiving end: fenced, labelled as data, never merged into the target's
instructions. Artifact references are named, never fetched (D5).

---

## 9. Vendor reach

`bridge/src/agents/registry.ts` holds nine agents. Every one declares a
`notificationSource` (`plugin` or `osc`), which is what the delivery queue reads
to know a session is idle — **so turn-boundary delivery already works for all
nine.** Injecting a line into a terminal asks nothing of the vendor.

Only **two declare an `mcp` profile**: `claude-code` (`registry.ts:57`) and
`codex` (`registry.ts:138`).

So the surface is asymmetric today, and this is the actual shape of "works across
vendors":

| Capability | Agents |
|---|---|
| Can be discovered, and receive `post` / `notify` | all nine |
| Carries a task-naming title, so its directory row is judgeable (`titleSource: "structured"`) | claude-code, codex, opencode, github-copilot |
| Can call the tools to send, reply, or read a mailbox (`mcp` profile) | claude-code, codex |

An agent that can receive but not send is a genuinely useful half — it can be
told something at a turn boundary — but it is a dead end in a thread, and the
directory must say so rather than offering it as a peer and letting the first
reply fail. Render it as reachable, not conversational.

The title axis degrades more gently than the send axis: the five `titleSource:
"osc"` agents still produce a row, just a weaker one (`"Cursor Agent"`), and
antigravity produces none worth showing — `oscTitleUnusable` is set because `agy`
publishes its own executable path. Those rows fall back to the session label and
lean on branch and last-activity to stay judgeable, which is precisely why §5.3
carries branch.

**Rollout is one MCP profile per vendor**, ordered by what each already has:
`opencode` first (it declares a `hookDir`, so a hook-based send path exists as a
fallback if its MCP support is weak), then the remaining `hookDir: null` agents,
each of which needs its own config-injection shape — the same per-agent work
`config-inject.ts` already does for notifications.

This is not an A2A problem and A2A would not fix it. It is tool injection, per
vendor, and it is countable.

---

## 10. Human interaction

### 10.1 Each session faces its own human

D4e made the lead the sole human-facing agent so that peers could not fill one
phone with questions. With no lead, the answer is not a new arbiter — it is that
**no session has any path to another session's human.**

An agent that needs a human decision asks its own user through its own session
channel, exactly as it does today. An agent that wants something from another
human asks *that session's agent*, which decides whether to involve its user.

This dissolves the approval-fatigue problem rather than solving it: there is no
cross-session human queue to flood, and permission gates continue to flow
machine-to-phone directly and unchanged.

### 10.2 Surfaces

No new screen (D14's spirit, carried):

- **Directory** — no human surface. The addressable set is the AGENT's read
  (`antgrid_list_sessions`), and §10.1 leaves a human-facing version with no
  action it is allowed to offer on any row: a modal spawning a branch read per
  project, to render rows nobody may act on, is cost with no decision behind
  it. `session-bus:directory` stays on the wire for a surface that earns one.
- **Mailbox** — not a tab. Most of a bus exchange is already in the primary
  view: a `notify` is written into the receiving PTY as a prompt (§5.2), and an
  outbound send is a tool call in the sender's transcript. What reaches neither
  is a `post` parked for an agent that has not looked, the mailbox's own
  discards, and the receipt on an outbound entry — so the surface is a SHEET.
  ONE door: a **Messages** row in the session kebab, shown for a session that
  has been on the bus at all and opening at zero unread.
- **No indication, anywhere.** Nothing announces that a peer wrote to a session —
  no badge on a row, no count, no dot on the kebab. The bus is agent-to-agent and
  §10.1 leaves no session a path to another session's human: nobody is blocked on
  the user, so nothing may ask for their attention on the bus's behalf. The
  kebab's dot stays an ESCALATION's alone, where a person really is what an agent
  is stopped on. A `session-bus:arrived` push still crosses the wire — whose
  mailbox grew, and no count — because a sheet already open on that mailbox has
  to re-read and nothing else would tell it to.
- **Thread view** — reuses the transcript's message rendering; a thread is a list
  of wrapped lines that already render.

A session that has only ever SENT is still unreachable from that door: the
app's two reads are the mailbox and one thread by id, and a thread id comes only
from an inbound post. A `session-bus:threads` read is what closes it.

The add-machine dialog, member tabs and the membership menu are removed.

---

## 11. Termination and scope bar

D1 gave the old feature a clean termination bar: the session ends when the
question is answered. Removing D1 removes that bar, and nothing about "sessions
message each other" says when to stop.

Replacement bar, and it is weaker on purpose: **a conversation is bounded by
budget, not by purpose** (§7.4). The no-progress halt is what ends an exchange
that is going nowhere, and a human clears it. There is no notion of a
conversation being "done", because peers do not close each other's work.

Flagged as the honest cost of the rescope, and it is the reason §7.4 is not
negotiable.

---

## 12. MVP scope

**In**

- Repo-keyed directory over connected machines; capability card served on
  demand and mirrored by the app (§5.3)
- Directory rows carrying generated title, branch, status and last activity, with
  the objective sort of §5.5
- Machine-level bus stores, routes and counters (§5.4)
- Local in-process transport; remote via the initiating machine's app
- `post`, `notify`, `inbox`, `list_sessions`, `reply` — plus artifact publish and
  list, carried over
- Threads as correlation; delivery receipts (E6)
- Turn-boundary injection, wrapped templates, one line per boundary
- Per-pair notify budget and no-progress halt
- Local open / remote gated by the existing switch
- MCP profiles: claude-code, codex

**Out**

- Broadcast and group threads
- Foreign agents; cross-owner sessions
- Shared working trees or context
- MCP profiles for the other seven vendors (roadmap, §9)
- Any task lifecycle, membership record, or session-spanning object

---

## 13. Open questions

1. **Mailbox bound.** How many posts, and is a dropped oldest post visible enough?
2. **Thread garbage.** Nothing closes a thread. Time-based expiry, or unbounded
   with a cap?
3. **Same-repo, different fork.** Two forks of one upstream normalize to
   different remotes and will not see each other; two clones of one fork will.
   Correct by default, but worth confirming against real usage.
4. **Judgeable rows for the five `osc` agents (§9).** Four of nine carry a
   task-naming title; the rest fall back to a label like `"Cursor Agent"` and
   lean entirely on branch and last activity. Is that enough to pick from, or
   does a session on one of those agents need a name the user sets by hand? Worth
   answering from live use rather than in advance — E11 argues against building a
   topic tool speculatively.
5. **Pricing.** Unchanged from the old spec's open question.

---

## 14. Decision log

**E1 — The session is the unit; the machine is transport.**
Interviews found nobody wanted to join machines. Addressing a session directly
makes same-machine and cross-machine one feature with one tool surface, and
turns the old design's central object (a session spanning machines) into
something with no reason to exist.

**E2 — No membership, and therefore nothing to clean up.**
Ownerless membership would need consensus for D11's deletion rules. Dropping
membership entirely is smaller than solving that: sessions already exist, already
have owners, and already end when their own user ends them. A conversation
between two live things needs no record of who belongs to what.

**E3 — Discovery is repo-keyed, over connected machines only.**
The normalized remote is already computed, already credential-stripped, already
matched on. Connectedness is not a compromise: a machine whose app is closed has
no bridge, so it is not a peer. Together they make the directory small, live and
honest, with no server-side index and no new disclosure.

**E4 — The address chooses the transport.**
Local is in-process with no relay, carrier, encryption leg or retry; remote uses
the initiating machine's app exactly as D7 described. Two paths, one decision
point, identical behaviour after it. Justified by same-machine being the common
case: routing it through a server would make the common case the fragile one.

**E5 — Agents may open conversations freely within the addressable set.**
No per-pair human approval. The bounds are the repo key, the remote-access
switch, and the budget — all three enforced by the bridge, none by an agent's
judgment. Accepted cost: an agent's words reach another agent with no human in
between, which is why §7.5's fencing is load-bearing rather than hygiene.

**E6 — Delivery receipts survive; the task lifecycle does not.**
These were always separable and only one of them is a task. A receipt answers
"did this land?", is already built, and is what stops a message vanishing while
its sender believes otherwise. `pending`/`working`/`completed`/`failed`/
`input-required` answered "is the delegated work done?", and there is no
delegation left to ask about.

**E7 — No session has a path to another session's human.**
Replaces D4e. Each agent asks its own user through its own channel; an agent
wanting something from another human asks that session's agent. There is no
cross-session human queue, so there is none to flood.

**E8 — Interruption is a verb, not a flag.**
`post` and `notify` are separate tools with separate costs. D4a established that
agents over-declare urgency; putting the cost on the verb puts it on the axis the
bias runs along. It is also fail-closed: an unknown verb is refused where an
unknown flag is silently misread.

**E9 — Bus state moves to the host server.**
Per-project stores cannot serve repo-keyed addressing, because one repo can be
open as several project ids. The directory, route table and budget counters
become machine-level. Largest structural change in the rescope, and the one that
makes a worktree session able to reach its parent.

**E10 — Vendor reach is an MCP profile per agent, not a protocol.**
All nine registry agents can already be delivered to, because every one declares
a notification source the delivery queue can read. Two can send. Closing the gap
is per-vendor config injection of the kind `config-inject.ts` already does — not
A2A, which solves interoperability between agents a vendor did not build and
would not add a single sender here.

**E11 — Relevance belongs to the agent; the bridge only sorts.**
The bridge would be guessing with strictly less context than the agent asking it.
So it bounds the candidate set (§5.1–5.2), renders a judgeable row from fields
that already exist (§5.5), sorts on objective facts, and stops. No score, no
semantic matching, and no topic an agent must remember to maintain — the
generated title already names the task and refreshes itself, and a stale
agent-maintained topic would be worse than none because it would be trusted. What
makes the residual uncertainty affordable is that `post` does not interrupt: an
agent resolves a half-guess by asking rather than by inferring harder. Claude
Code's `ListAgents` validates the architecture and, at 149 rows keyed on
directory name, measures its failure mode — the row breaks first, not the flat
list.

**E12 — Agent reach is its own bit, subordinate to the remote-access switch.**
Reverses this spec's earlier "deliberately not a new bit". The argument against a
second switch was discovery — a second thing off by default that a user must find
before anything works — and that objection is answered by the default rather than
by the absence of the switch: *reachable by agents* defaults on and is inert
while remote access is off, so the working path is unchanged and the bit exists
only for the user who wants devices-yes / agents-no. What makes it worth having
is that the two bits do not make the same promise. Remote access says *my other
devices may drive this machine*, with a human at the far end of every frame.
Agent reach says *a program on another of my machines may read what I am working
on and interrupt me about it, with nobody watching* — and the remote half made
the reading half real, not prospective. It gates disclosure and interruption
together: separating them would allow an agent to message a session it is not
allowed to see. Independent of remote access was refused outright — remote access
is the sole authorization store and off is machine-wide and immediate.

**E13 — A missed peek warms the peer it missed.**
The directory asks only the peer control planes the desktop already holds, and a
desktop at rest holds none, so the honest first answer is usually *no peer asked
at all*. Rather than make that permanent or pay to prevent it, a miss marks the
peer wanted so the next ask has it: thin once, then real. This keeps E4's
push-not-pull intact — `list_sessions` still reads memory and never blocks on a
network — where pinning peers by shared repo key would hold standing connections
on an idle desktop to keep fresh an answer nobody has asked for. The cost is that
the first ask after a cold start under-reports, which the reach line already
states rather than hides. `sessionBusLinksProvider` gets its real source from
ADDRESSING instead: a leg exists only once an agent has actually reached for one,
and is released when nothing has been carried over it, so an idle desktop holds
no peer sockets at all.

**E14 — The card answers the session that asked.**
A session-bearing capability card was published to the control-plane channel,
which reaches every established app session on the answering machine, phone
included, correlated only by `requestId` at the client. Not a new class of
disclosure — `sessions.list` already hands `SessionEntry.name` to the same set,
though on the remote-access gate alone (§8.1) rather than this one — but it was
an oversight rather than a decision, and the asking `peerId` is already threaded
into the control-plane dispatch, where `RelayClient.sendOnChannel` takes a
`SendTarget`.

The fallback is the bus, and *only* when the asker cannot be named: a loopback
frame carries no `peerId`. A named asker whose session has since gone resolves
to no recipient and the frame is dropped, which is right — the asker it was
assembled for left. Testing that liveness first and falling back to the bus
would broadcast precisely the answer that lost its reader.

Every other verb answered from one asker's params travels the same way, for a
second reason: a client correlates a response by `requestId` alone, and those
are per-transport counters that two devices on one bridge both start at zero, so
a fanned answer can complete a different device's pending request with a payload
it never asked for. `state.snapshot` stays on the bus — every session would have
asked for it anyway.
