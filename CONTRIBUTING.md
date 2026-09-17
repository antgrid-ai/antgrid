# Contributing to Antgrid

Antgrid is pre-v1 with two maintainers. We would rather review a few changes
properly than collect a queue we cannot answer.

## Where changes go

| | |
|---|---|
| **Straight to a PR** | `docs/`, `site/`, `README.md`, `DEVELOPMENT.md`, typos, dead links, tests for existing behaviour |
| **Issue first** | `bridge/`, `app/`, `packages/`, `evals/`, `scripts/` — we agree the approach, then the PR is welcome |
| **Closed** | `relay/`, `web/`, `packages/antgrid-wire` — see [Contribution terms](#contribution-terms) |

Issue-first is not a formality: the architecture still moves, and several
contracts are mirrored by hand with no test spanning both sides.

Bug reports with a clear reproduction are the most useful thing you can send.
Please read the [Code of Conduct](CODE_OF_CONDUCT.md) first.

## Contracts no test will catch

[CLAUDE.md](CLAUDE.md) is the authoritative list, and each component has its own
(`bridge/CLAUDE.md`, `app/CLAUDE.md`, …). Read the one you are touching. A green
test run will not tell you that:

- **A new message type touches five places** — the schema, `AbMessageSchema` and
  `KNOWN_TYPES` in `bridge/src/protocol.ts`, the exported type, and the
  `handleAbMessage` switch in `bridge/src/agent-core.ts`. Miss one and it fails
  silently.
- **Two lists are mirrored by hand across the bridge/app wire.**
  `CHECKOUT_VARIABLE_MESSAGE_TYPES` ↔ `kCheckoutVariableMessageTypes`
  (`app/lib/project/project_message_classification.dart`), and the app's hello
  capability literals in `packages/antgrid_relay_client` ↔
  `AppReadyMessage.capabilities`. Zod strips an undeclared key rather than
  rejecting it, so both drift in silence.
- **`FRAME_VERSION`** (`packages/antgrid-wire/src/frame.ts`) is mirrored by hand
  in the Dart client.
- **The command-execution gate is deliberately not redundant.**
  `bridge/src/remote-access-policy.ts` is the only authorization store;
  `seenProjects` (`bridge/src/host-server.ts`) and `isSafeProjectId`
  (`bridge/src/project-id.ts`) are the only bound on which project a remote phone
  may name. Please do not tidy them away.
- **Encryption is never optional.**
- **App UI uses `app/lib/design/` only** — no raw Material widgets, no `Icons.*`,
  no inline colour or spacing literals. `npm run check:font-tokens` catches raw
  `fontSize:` and nothing else.

## Building and testing

[DEVELOPMENT.md](DEVELOPMENT.md) covers setup and platform traps;
[docs/architecture.md](docs/architecture.md) covers message flow.

Run the tests for what you touched and say which ones, on which platform. If you
could not run something, say that too — it is useful, not disqualifying.

**Never run a bare `bun test` from the repository root.** It recurses into
`evals/`, which starts real agents, relays and PTYs in one port space. Use the
per-workspace scripts.

## Licence

First-party source and documentation are MPL-2.0 except `relay/` and `web/`,
which are Elastic-2.0. [LICENSING.md](LICENSING.md) is the map, and states what
MPL does and does not reach.

The Antgrid name and artwork are separate from the source licence; a distributed
modified build must rebrand. See
[BRAND-ASSETS-LICENSE.md](BRAND-ASSETS-LICENSE.md) and
[TRADEMARK.md](TRADEMARK.md).

## Contribution terms

You contribute under **the licence applying to the files you touched**, as
[LICENSING.md](LICENSING.md) maps them, and you confirm you may license it under
those terms. That is ordinary inbound-equals-outbound, per
[GitHub ToS §D.6](https://docs.github.com/site-policy/github-terms/github-terms-of-service#6-contributions-under-repository-license).
It is stated here because GitHub displays one licence for a repository —
MPL-2.0, from the root `LICENSE.md` — and the nearest scoped licence controls
instead.

**`relay/`, `web/` and `packages/antgrid-wire` are closed to outside patches.**
A contribution arriving under the repository's MPL-2.0 notice would land in an
ELv2 file, and neither licence lets us relicense it; `antgrid-wire` is imported
by both services, so a contribution there is MPL-2.0 permanently. This is a
licensing constraint, not a judgement on any change, and it is permanent. An
issue is worth as much to us for those paths.

## Security

Do not report security problems through issues or pull requests. Follow
[SECURITY.md](SECURITY.md) instead.
