# Agent adapters

This MPL-2.0 workspace owns built-in agent definitions, provider implementations,
normalized event schemas, shared chat state, and external integration assets.
The bridge owns account authorization, encrypted transport, checkout selection,
process containment, and durable session state.

Public exports are declared in `package.json`. Import `antgrid-agents/contracts`
for adapter interfaces without loading provider SDKs, `antgrid-agents/builtins`
for the trusted built-in registry, and `antgrid-agents/assets` to materialize
integration files. Package code must never import bridge internals.

The host creates `createAgentRuntime({ registry, host })` from
`antgrid-agents/runtime`. Each runtime snapshots its definitions and binds logging,
state storage, hook resolution, and process services to its own operations.
Hosts exposing session tools also provide `mcpCommand()`. The optional adapter
`mcp.inject` operation receives that command and supplies its own configuration
or arguments. Hook and MCP injection fail independently, so losing one does not
remove the other integration.
Terminal adapters
receive semantic conversation intent and a host-selected working directory;
their launch preparation may be asynchronous. Raw shell input remains distinct
from ordinary argv. Resources allocated during preparation belong to the run and
must be released on cancellation, failed dispatch, or termination.

Adapter authors use `contracts`, `events`, `registry`, and `runtime` as the
extension boundary. Register an `AgentDefinition` with `apiVersion: AGENT_API_VERSION`,
a stable hook alias (or null), and a `create(host)` factory. Runtime construction
rejects incompatible API versions and invalid registrations. The public-only
example in `tests/fixtures/service-adapter.ts` demonstrates a non-CLI adapter.

`cli` is optional. An adapter can implement asynchronous `discover` and
`prepareTerminal`, and provide headless `run` or update `check`/`apply` operations.
Conversation, approval, and observation capabilities describe behavior; CLI flags
live under `cli`. Headless operations declare their history guarantee and return
normalized usage. Availability does not require an executable path.

Register resources with the supplied run scope immediately after allocation,
including resources allocated before preparation completes. Observe its abort
signal and emit through its guarded sink. Teardown waits for tracked acquisition
and cleanup, attempts every cleanup, and retains failures. Terminal `attach`
represents readiness; adapter prompt delivery runs after attachment. Driver
`start()` resolves readiness and reports native identity through its callback.

Register built-ins in `src/agents/registry.ts`. Native IDs and hook aliases must
remain stable across releases because saved sessions and trusted hook commands
refer to them. The registry validates duplicate IDs and aliases. Dynamic plugin
installation and loading are intentionally outside this package's current scope.

Normalized payload schemas live in `src/payloads.ts`; bridge composes its wire
metadata around those schemas. Runtime events retain event IDs and timestamps,
including historical replay timestamps. Replays remain atomic batches.

Assets use Bun text imports so compiled executables carry their contents.
`materializeAgentAssets` writes content-addressed files into host-selected storage.
Do not delete an old content directory while an external agent may still use it.

Run tests and typechecks from the workspace root:

```text
bun run --filter antgrid-agents test
bun run --filter antgrid-agents typecheck
bun run --filter antgrid-agents smoke:assets
bun run --filter antgrid-bridge test
bun run --filter antgrid-bridge typecheck
```

`scripts/smoke-assets.ts` can be compiled with Bun and run from a temporary
directory outside the checkout to verify external Bun and Node asset loading.
