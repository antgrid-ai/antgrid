# Contributing to Antgrid

## Pull requests are closed for now

**Antgrid is not accepting external pull requests yet.** If you open one, we will
close it — not because the change is unwelcome, but because we are not in a
position to merge it. That is a real answer, and we would rather give it up front
than leave your branch sitting open for months.

The reason is the licence. Most of Antgrid ships under the [Elastic License
2.0](LICENSE.md), whose grant is expressly non-sublicensable. Accepting patches
under it would leave us unable to pass your work on to our own users, or to run
it in the hosted relay. Doing this properly needs a contributor licence
agreement, and setting one up is not something to rush while the project is still
finding its shape.

So this is a *not yet*, with a specific blocker attached. When the CLA is in
place this file will be rewritten and the door opens.

Two packages are exceptions to the licence, though not yet to the policy.
`packages/antgrid-wire` and `packages/antgrid_relay_client` are Apache-2.0, whose
§5 makes contributions outbound-licensed without a CLA, so the blocker above
genuinely does not apply to them. They are the likeliest place for the door to
open first. It has not opened yet — for now the answer above covers the whole
repository.

None of that restricts what you can do with the code. Read it, fork it, modify
it, self-host it — the licence grants all of that, and none of it needs our
permission. The only thing on hold is sending changes back upstream.

## What genuinely helps right now

- **Bug reports.** The most useful thing you can send. A clear reproduction
  against the latest release is worth more to us today than a patch we cannot
  merge. [Open an issue](https://github.com/antgrid-ai/antgrid/issues).
- **Feature ideas and design pushback.** Open an issue and argue for it.
  Especially on the wire protocol and the security model — the protocol is
  mirrored by hand between TypeScript and Dart, so design mistakes there are
  expensive to unwind later.
- **Telling us the docs are wrong.** If [DEVELOPMENT.md](DEVELOPMENT.md) fails
  you on a clean machine, that is a bug and we want to hear it.

Please read the [Code of Conduct](CODE_OF_CONDUCT.md) before taking part.

## Building it yourself

[**DEVELOPMENT.md**](DEVELOPMENT.md) is the full guide: prerequisites, the "pick
your scope" table so you install only what your work needs, the per-workspace
test commands, and the platform traps worth knowing before you file a build
problem as a bug. Most of the repo needs only [Bun](https://bun.sh) — the full
stack additionally wants [Flutter](https://flutter.dev) and a Postgres.

For how the pieces fit together, [`docs/architecture.md`](docs/architecture.md)
covers the message flow and the `antgrid.yaml` schema, and
[`CLAUDE.md`](CLAUDE.md) holds the conventions the codebase is actually held to —
the invariants that fail silently when broken, which is the part worth reading
before you change anything in a fork.

## Licence

Antgrid is source-available under the [Elastic License 2.0](LICENSE.md). You can
read it, modify it and self-host it; you cannot offer it to third parties as a
hosted service or circumvent the licence-key functionality. It is not an OSI
open-source licence, and we do not describe it as one.

`packages/antgrid-wire` and `packages/antgrid_relay_client` — the wire protocol
and the client-side end-to-end encryption — are Apache-2.0 instead, so that
anyone can build an Antgrid client and audit the cryptography.

The Antgrid name, logo and application identifiers are *not* covered by the
licence — see [TRADEMARK.md](TRADEMARK.md) if you intend to distribute a fork.
It lists every identifier you need to change, including the publisher strings
compiled into the Windows and macOS binaries.

## Security

Do not report security problems through issues or pull requests. Follow
[SECURITY.md](SECURITY.md) instead.
