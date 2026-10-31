# antgrid-memory

Local memory storage and policy for Antgrid. This private MPL-2.0 Bun workspace
has no bridge dependency. A host must supply a verified `MemoryContext` or a
synchronous resolver that revalidates it on every attempt.

```ts
const service = new MemoryService({ directory: profileMemoryDirectory });
await service.execute(verifiedAppContext, { op: "settings", enabled: true });
const result = await service.execute(resolveLiveAgentContext, {
  op: "search", query: '"build failure" JDK',
});
service.close();
```

The owner ID comes from `service.ownerId`, which is retained in the database.
Agents require a project, durable session, checkout, and verified live run.
The run secret is checked by the host and never persisted. App contexts without
a project see every local record; project app contexts see that project's
records only. A `project_id` on an app request can only narrow: a machine app
context may narrow to one project, a project context can never widen or switch
(a different project is `FORBIDDEN`), and agents can never pass it.
Scopes are `project` and `task`. App saves are corrections of
existing records and cannot widen their scope. While memory is disabled every
agent operation except `status` is refused with `DISABLED`; app inspection,
export and forgetting remain available.

App inspection adds a few operations and options. `projects` lists every project
with its memory and earlier-version counts and its pause state. `list` and
`search` take `versions` (`current`, `earlier`, and `all` on `list`), `offset`
and `memory_type`, and return `total`; app search results are complete records,
and a query with no searchable tokens is an empty result for the app, while an
unavailable index is still `SEARCH_UNAVAILABLE`. `get` with `earlier` returns
the correction chain behind a memory, newest first. App `status` carries
`failures` (conflicted corrections with the latest version to retry against), and
`dismiss` acknowledges one without making its operation key replayable. Agents
are refused every one of these options.

The service owns write serialization, immediate SQLite transactions, default
opt-out and pause controls, correction conflicts, task-state inactivity expiry,
FTS5 ranking/filtering, durable operation receipts, pending save recovery,
forget/replay suppression, and export. Agent adapters call `prepare` before
dispatching `save` with the same durable operation key. `recover` handles only
that verified durable session's queue. No other database connection is needed
in an MCP child. An adapter doing its own bounded retries must pass
`{ maxAttempts: 1 }` through its host route to avoid multiplying retry budgets.

`MemoryError.code` distinguishes validation/access refusals, disabled/paused
saving, conflicts, busy storage, unavailable search, and cleanup failure.
Never convert an unavailable search into an empty successful result. A lost
transport reply is an unknown outcome; reuse the original operation key.

Run `bun run --filter antgrid-memory test` and
`bun run --filter antgrid-memory typecheck` from the repository root.
The [RFC](../../docs/agent-memory-rfc.md) is the behavior contract.
