# Agent architecture improvement plan

Status: implemented; validation notes below.

Implement in six stages. Dynamic plugin installation and loading remain a later step.

## 1. Fix chat lifecycle correctness

- Make Start after an aborted startup wait for teardown and create a replacement.
- Add run-specific startup success/failure transitions.
- Clear running state and invalidate hook identity after failed startup.
- Guarantee backend disposal even when callbacks or event delivery throw.
- Test rapid Stop → Start, failed startup → retry, and callback failures during disposal.

## 2. Bind runtime services to one registry

- Introduce `createAgentRuntime({ registry, host })`.
- Route launch, discovery, hooks, catalog, and capability lookup through that runtime.
- Replace mutable global host-service lookup with instance-bound services.
- Keep built-ins as the default registry.
- Test two independent runtimes and verify custom registrations reach every consumer.

## 3. Make capabilities describe behavior

- Separate native-fork and approval-policy support from argument builders.
- Let terminal observation declare supported events independently of hook transport.
- Move platform integration registration into adapter definitions.
- Retain CLI argument builders as optional implementation helpers.
- Test an adapter that forks and applies approval policy through configuration or an API.

## 4. Complete the invocation and lifecycle contracts

- Introduce a host-created run scope containing cancellation, run identity, guarded event sinks, and early cleanup registration.
- Add a limited post-spawn readiness and prompt-delivery interface.
- Narrow driver output to adapter-originated events.
- Report native session identity through one event path; let startup completion represent readiness.
- Test cancellation during preparation, partial allocation failure, late events, and delayed readiness.

## 5. Support discovery and operations beyond CLIs

- Add asynchronous discovery with explicit availability and failure reasons.
- Keep PATH probing as a standard helper.
- Allow optional headless and update operation implementations alongside existing CLI helpers.
- Preserve headless access restrictions, history guarantees, cancellation, and usage reporting.
- Test an SDK/service-backed adapter with no dedicated PATH executable.

## 6. Validate the extension boundary

- Add a synthetic external adapter using public exports only.
- Demonstrate registration, discovery, startup, observation, fork, failure, and teardown without bridge modifications.
- Define the supported plugin-facing exports and API compatibility version.
- Validate registrations and prevent mutable definitions from invalidating registry indexes.
- Wire compiled asset smoke tests into release CI.

## Delivery and validation

Each stage should be a separate reviewable commit with focused tests. Run package and bridge tests/typechecks for integration changes:

```text
bun run --filter antgrid-agents test
bun run --filter antgrid-agents typecheck
bun run --filter antgrid-bridge test
bun run --filter antgrid-bridge typecheck
```

If capability payloads change, update and validate the corresponding app models and consumers in the same stage.

## Completion criterion

A substantially different agent can integrate through its adapter alone, and every startup outcome leaves session state and owned resources consistent.

## Implementation notes

`packages/antgrid-agents/src/runtime.ts` constructs versioned, immutable registries
with instance-bound host services. `src/run-scope.ts` owns cancellation, guarded
events, resource acquisition, and cleanup. Behavioral capabilities are separate
from the optional CLI helpers in `AgentSpec.cli`.

The public-only service adapter in `tests/fixtures/service-adapter.ts` and the
bridge's `external-agent-runtime.test.ts` exercise discovery without an executable,
configuration-based fork and approval policy, readiness, identity, headless work,
updates, and disposal. The bridge composition point is `bridge/src/agent-host.ts`.
Dynamic loading remains outside this change.

Package tests, package and bridge typechecks, focused bridge integration tests,
Flutter model tests and analysis, and the compiled asset smoke check passed.
The full bridge gate has four Windows graceful-exit failures. The same four
failures reproduce using copies of the committed terminal session, manager, and
platform implementation; they are not introduced by this migration.
