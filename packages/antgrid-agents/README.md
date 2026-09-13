# Agent adapters

This ELv2 workspace owns built-in agent definitions, provider implementations,
normalized event schemas, shared chat state, and external integration assets.
The bridge owns account authorization, encrypted transport, checkout selection,
process containment, and durable session state.

Public exports are declared in `package.json`. Import `antgrid-agents/contracts`
for adapter interfaces without loading provider SDKs, `antgrid-agents/builtins`
for the trusted built-in registry, and `antgrid-agents/assets` to materialize
integration files. Package code must never import bridge internals.

The host binds logging, state storage, hook command resolution, and process
services through `configureAgentHost` before starting adapters. Terminal adapters
receive semantic conversation intent and a host-selected working directory;
their launch preparation may be asynchronous. Raw shell input remains distinct
from ordinary argv. Resources allocated during preparation belong to the run and
must be released on cancellation, failed dispatch, or termination.

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
bun run --filter antgrid-bridge test
bun run --filter antgrid-bridge typecheck
```

`scripts/smoke-assets.ts` can be compiled with Bun and run from a temporary
directory outside the checkout to verify external Bun and Node asset loading.
