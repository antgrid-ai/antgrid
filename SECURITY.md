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

Enough detail to aim at the parts that matter. The peer session protocol —
admission, the plaintext session hello, and per-channel flow control — is
specified at [`docs/protocol/peer-session.md`](docs/protocol/peer-session.md).
The implementations are `bridge/src/peer-session-owner.ts` and
`bridge/src/peer/native-host-connection.ts` (TypeScript),
`packages/antgrid_relay_client/lib/src/connection_handshake.dart` and
`machine_session.dart` (Dart), and `relay/src/` for the *central* control
socket's admission and routing (a separate concern from the payload path
below).

The Dart implementation and the wire protocol it speaks
(`packages/antgrid_relay_client` and `packages/antgrid-wire`) are Apache-2.0, not
ELv2, precisely so this claim can be checked: the licence lets you read, fork and
reimplement that code, and publish your own work built on it, without asking us.
That is a copyright grant and nothing more — the disclosure window above still
applies to anything you find.

**App to bridge payload traffic is end-to-end encrypted between your devices
(QUIC/TLS 1.3); relays cannot read content.** Every native connection is a QUIC
connection directly between the app's and the bridge's own Iroh endpoints —
TLS 1.3, terminated at the two endpoints only. Admission is gated on the
endpoint ID presented at the QUIC layer being one the bridge's authorization
lease names for that account (`acceptPeer`); nothing the peer sends over the
connection is trusted to prove its own identity. Once admitted, a single
plaintext `session:hello`/`established` exchange starts the session — there is
no session key for this layer to protect, because QUIC/TLS is already the
confidentiality boundary underneath it. Two different relays sit outside this
boundary and see neither plaintext nor keys: the **Iroh relay**, used only when
a direct path is unavailable, forwards already-TLS-encrypted QUIC packets
between the two endpoints without terminating them; the **central Antgrid
relay** (below) never carries payload traffic at all.

**The central relay authenticates devices and never carries payloads.** It
authenticates each control socket from a single Ed25519-signed `hello` frame
and will only route control-plane traffic (presence, policy, push) between
devices belonging to the same account. It has no role in payload admission or
delivery — see the licence-gate claim below for what it does check.

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

- **The peer payload transport.** Anything that lets a party other than the
  intended peer read, modify, or replay app-to-bridge payload traffic; any way
  to have a connection admitted whose QUIC-authenticated endpoint ID is not the
  one the authorization lease names for it; any way to dispatch a frame from a
  peer that has not completed the plaintext session hello, or to have a frame
  attributed to a peer other than the one the connection actually
  authenticates as. Cross-language interop vectors for the session-record and
  stream-open formats live in `evals/fixtures/peer-transport-vectors.json` if
  you want a starting point.
- **The relays' zero-knowledge property**, for both the Iroh relay (packet
  forwarding only) and the central Antgrid relay (control-plane only).
  Anything that lets either one, or someone who controls it, recover payload
  plaintext, act as a payload man-in-the-middle, or route frames between
  devices on different accounts.
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
