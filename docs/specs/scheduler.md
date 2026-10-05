# Cron scheduler with schedule-owned worktrees

Scheduler sits directly below New Session in the drawer and opens without a
selected project. Desktop and mobile clients manage schedules and run history on
the selected machine. Desktop defaults to the local machine; mobile defaults to
the most recently connected machine. The target desktop app must remain open.

## Management

Schedules and Runs tabs share a machine selector. Schedules show name, project,
cron, timezone, enabled state, next occurrence and last result. Actions are
Create, Edit, Pause/Resume, Run now and Delete. Runs show occurrence time, status,
duration and failure/skip reason, with Open session and Stop run actions.

The editor saves name, host-catalog project, installed agent, terminal/chat mode,
prompt, approval policy, workspace choice, base branch, cron and an explicit IANA
timezone. Normal approvals are the default. Git projects default to isolated
worktrees; non-Git projects use shared workspaces. Hourly, daily and weekday
presets and custom cron use host validation and host-calculated next five times.
Unavailable machines and older bridges show an explicit state. Disconnected
clients cannot write. Lists refresh after actions and every five seconds while
visible. All app UI uses the Antgrid design system.

## Execution and persistence

The machine-level bridge host owns execution independently of project selection
or client connectivity. Only desktop-owned hosts execute schedules, within the
existing app-close and owner-watchdog lifetime.

An Antgrid wrapper around [cron-parser](https://github.com/harrisiirak/cron-parser/blob/master/README.md)
accepts five numeric fields with wildcards, lists, ranges and steps. Seconds,
macros and extended syntax are rejected. Standard day-of-month/day-of-week and
timezone/DST semantics apply. Timezone defaults to the target host's timezone.

Schedules and runs live in a separate machine-local SQLite store. Transactional
claims and one scheduler owner per state directory prevent duplicate execution.
Storage failure prevents execution and is visible in capabilities. Startup and
resume skip missed work, recording a consolidated missed interval; they never
replay it. One run per schedule and two scheduled runs per machine may be active.
Overlap and capacity produce skipped records, without a queue. Run now obeys
these limits and leaves the timetable unchanged.

Each occurrence creates a fresh agent conversation. A worktree belongs to its
schedule and is created lazily through the existing setup lifecycle. All later
runs reuse it without reset, pull, recreation or automatic repeated setup. Files,
commits, branch changes and uncommitted work survive. Project, workspace and base
branch become immutable after workspace creation. Session deletion, including
the last session, cannot delete a schedule-owned checkout. Missing checkouts or
forgotten projects fail explicitly without workspace substitution.

Schedule deletion stops future occurrences and releases checkout ownership. It
retains runs, sessions, worktree and branch and does not stop an active run.
Existing explicit workspace cleanup may subsequently apply.

## Host protocol and lifecycle

Capabilities, list, preview, create, update, delete, run now, runs and stop use
loopback control requests locally and generic RPC envelopes on authenticated
native machine streams remotely. Both paths share Zod validation and execution.
Public models are mirrored in Dart. Capabilities advertise timezone and only
installed agent/mode combinations supporting opening prompts and explicit turn
completion; unsupported selections cannot be saved.

The host resolves all project and checkout paths. Remote requests require account
authorization, the machine remote-access switch, safe project IDs and catalog
membership. Replies target the requesting peer. Remotely authored execution
settings retain the authorizing device, rechecked before dispatch; unavailable
authorization skips the occurrence. Locally authored schedules use loopback
semantics.

An awaitable launch path reports errors and persists session/runtime identity
before prompt delivery. Restart recovery marks uncertain launches interrupted
without resubmission. Preparing, Running, Needs input, Completed, Failed,
Interrupted and Skipped are recorded using explicit agent lifecycle signals
matched to the launched session and runtime generation. Completion records the
scheduled prompt's turn ending, not independent verification of its outcome.
Permission requests show Needs input; no Handler arming or automatic approval is
added. Completion frees the overlap slot and leaves the agent session open for
follow-up. Later manual turns cannot modify the recorded result. Active runs
protect their projects from LRU eviction.

Keep the latest 500 terminal run records per schedule plus all active records.
Pruning never deletes sessions or worktrees. Diagnostics contain identifiers,
timestamps, states and reasons, never prompts.

## Verification

Cover cron syntax, presets, timezone/DST and preview/execution agreement;
pause/edit/delete, overlaps, capacity, missed intervals, restart recovery,
duplicate claims, storage faults and uncertain launches; durable checkout reuse,
single provisioning and accumulated changes; launch failure, input requests,
completion, cancellation, stale events and open completed sessions; remote
authorization/revocation/switch/catalog/requester replies and older bridges;
navigation, layouts, validation, actions, history and opening sessions. Run bridge
and agent-package tests/typechecks, relevant Flutter tests, font-token validation,
one nonconcurrent Flutter analysis gate and an explicit native transport eval.
