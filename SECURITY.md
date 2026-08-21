# Security policy

Antgrid's central claim is that the relay cannot read your traffic and that no
one can run commands on your machine without your account and your consent. If
you can break either of those, we want to hear about it before anyone else does.

## Reporting a vulnerability

Do not open a public GitHub issue, discussion, or pull request for a security
problem.

Report privately through one of these channels:

1. **GitHub private vulnerability reporting (preferred).** Use the "Report a
   vulnerability" button under the Security tab of this repository:
   <https://github.com/antgrid-ai/antgrid/security/advisories/new>
2. **Email.** Send details to <contact@radhaai.com> with "Security" in the
   subject line.

Please include as much of the following as you have:

- What the issue is and what an attacker gains from it.
- Which component is affected — App, Bridge, Relay, or Web — and the version, or
  the commit SHA if you built from source.
- Steps to reproduce, or a proof of concept. Test vectors, a packet capture, or a
  failing script are all more useful than a description.
- Whether the attack needs relay-mediated remote access, or works against a
  purely local setup.
- Any remediation you would suggest.

Please test against your own account and your own machines. Do not access other
people's data, degrade the hosted relay for other users, or pivot further into
our infrastructure than you need to in order to demonstrate the issue.

## What to expect

- We acknowledge reports within 3 business days.
- We tell you what we found and keep you updated while we work on a fix.
- We credit you in the release notes if you want it — tell us the name or handle
  to use, or say you would rather stay anonymous.
- We ask for a reasonable window to ship a fix before you disclose publicly, and
  we will tell you when the fix is out.

## The security model

Enough detail to aim at the parts that matter. The handshake is specified in
full, including its threat model and cross-language test vectors, at
[`docs/protocol/e2e-handshake.md`](docs/protocol/e2e-handshake.md). The
implementations are `bridge/src/e2e/` (TypeScript),
`packages/antgrid_relay_client/lib/src/e2e/` (Dart), and `relay/src/` for
admission and routing.

The Dart implementation and the wire protocol it speaks
(`packages/antgrid_relay_client` and `packages/antgrid-wire`) are Apache-2.0, not
ELv2, precisely so this claim can be checked: the licence lets you read, fork and
reimplement that code, and publish your own work built on it, without asking us.
That is a copyright grant and nothing more — the disclosure window above still
applies to anything you find.

**App to bridge traffic is end-to-end encrypted.** Session keys come from a fresh
X25519 ephemeral Diffie-Hellman exchange on every handshake, authenticated in
both directions by Ed25519 signatures over a canonical transcript that binds both
identities, both ephemeral keys, and a nonce. Transport is AES-256-GCM with
separate keys per direction. Establishment is gated on HMAC key-confirmation tags
compared in constant time, so no application traffic is dispatched on unconfirmed
keys. Session keys are per-connection and are never written to disk. Their
backing buffers are overwritten on teardown — best-effort, since both runtimes
are garbage-collected and we cannot guarantee no copy survives in unreachable
memory. Residual key material in a process dump is expected and is not treated
as a vulnerability.

**The relay routes frames and never holds decryption keys.** It authenticates
each socket from a single signed `hello` frame and will only route between
devices belonging to the same account. Payloads, including the stream envelope,
are opaque ciphertext to it. A relay operator who tampers with a key exchange
cannot produce a valid transcript signature, so the peer rejects the session.

**Command execution on your machine is gated three ways, and all three must
hold.** A remote device may drive a project only if it is trusted through your
signed-in account's device inventory, *and* the machine's remote-access switch is
on, *and* the project is one the host already knows about. That switch is a
single machine-wide boolean, off on a fresh install, and turning it off takes
effect immediately and everywhere on that machine. Local (loopback) callers are
exempt by design: the desktop app drives its own machine with the switch off.

**The relay enforces a licence gate at connect time.** An agent is admitted only
with a valid Ed25519-signed device token issued by the licensing service and
bound to the public key presented in its `hello`; apps present their own account
token.

## Scope

In scope. These are the claims worth attacking:

- **The end-to-end transport.** Anything that lets a party other than the
  intended peer read, modify, or replay app-to-bridge traffic; any downgrade to
  plaintext; any way to make two honest parties derive the same keys while
  misidentifying each other; any flaw in the transcript, key schedule, key
  confirmation, or AES-GCM framing. Cross-language interop vectors live in
  `evals/fixtures/e2e-handshake-vectors.json` if you want a starting point.
- **The relay's zero-knowledge property.** Anything that lets the relay, or
  someone who controls it, recover plaintext or key material, act as a
  man-in-the-middle, or route frames between devices on different accounts.
- **The command-execution authorization path.** Any way a remote device runs
  commands, reads files, opens a terminal, or reaches a preview tunnel on a
  machine whose remote-access switch is off; any way to reach a project outside
  the host's catalog; any way to be treated as account-trusted without being on
  the account.
- **The licence and relay gate.** Connecting to the relay without a valid device
  token, with a revoked or expired one, or with a token bound to a different
  device's key.
- **The bridge's local surfaces** — the loopback control plane, the HTTP
  tunnelling of local dev ports, and on-disk state under the Antgrid directory —
  where they can be reached by something other than the machine's own user.
- **The web service** at `app.antgrid.ai`: sign-in, device provisioning, token
  minting, and subscription enforcement.
- **The code in this repository and the published clients**, including the
  hosted services it builds: `relay.antgrid.ai`, `app.antgrid.ai`, and
  `antgrid.ai`.

Out of scope:

- Denial of service and volumetric attacks, including exhausting relay rate
  limits or connection caps.
- Social engineering of Antgrid users, contributors, or staff.
- Findings that require an already-compromised device, physical access, or a
  malicious local user on the machine running the bridge. That user already has
  the developer's shell; the bridge does not defend against them.
- Third-party services and dependencies. Report those to their vendor — though
  do tell us if we ship a version you can show is vulnerable in our context.
- Missing hardening headers, TLS configuration preferences, and other scanner
  output with no demonstrated impact.

## Supported versions

Only the latest release receives security fixes. There are no maintained release
branches and nothing is backported, however recently an earlier version shipped —
so if you are not on the newest build, assume it is unsupported. Where you can,
verify a finding against the current release, or against the `development` branch
if you are building from source — `development` is the integration branch, not
`main`.
