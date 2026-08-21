# Sign-out clears the push token only on agents with a warm project session

**Found:** 2026-07-20, during Task 6 Step 10 of the `push`-package migration
(`feat/encrypted-push`, Android release build on device RZCW90YW9SY).

**Not a regression from the `push` migration** — `clearToken` predates it and is
unchanged by it.

## Symptom

Signing out left the agent's stored `pushToken` and `pushPubkey` intact.
`~/.antgrid/host.log` shows no `Cleared push token for phone …` line and no
`push:register clear failed` — nothing was attempted at all.

## Root cause

`PushMessagingService.clearToken` (`app/lib/services/push_messaging_service.dart:246`)
iterates the currently warm sessions and skips anything that isn't a relay
project session:

```dart
for (final s in sessions) {
  if (s.mode != ProjectSessionMode.relay) continue;
  await s.send(createAbMessage('push:register', {'pushToken': '', …}));
}
```

At the moment of sign-out only the bare-`deviceUuid` control plane was
connected — the project session had gone offline six minutes earlier:

```
19:35:51.475  Peer offline: …#cd1429de….f5ebd3ca8639dfb8   ← project session gone
19:42:10.430  Paired with Antgrid App (…#cd1429de…)          ← control plane only
19:42:26      (web) DELETE /account/devices/…                ← sign-out
```

So the loop had nothing to iterate. This is not a race with the device deletion
tearing down the transport — the send was never attempted.

## Consequence

The clear reaches only the agents you happen to have a warm project session with
at that instant. Every other paired agent retains a live FCM token and push
pubkey for a signed-out user and will keep pushing to that device.

The blast radius is bounded — the agent is already a trusted, paired peer and
the notification is E2E-sealed to a key the device still holds — so this is a
hygiene and expectation gap rather than a disclosure to an untrusted party. But
"sign out" reasonably implies "stop notifying this device", and today it doesn't.

## Suggested fix

Two options, not mutually exclusive:

1. **Route the clear through the control plane.** It is the always-on
   machine-level connection and is far more likely to be up at sign-out than any
   given project session. This is the smaller change and fixes the common case.

2. **Make it durable rather than best-effort.** Record a pending-clear locally
   and re-send on the next successful pair, so an agent that was offline at
   sign-out still gets the clear when it next sees the phone.

Option 1 alone would have fixed the observed case. Option 2 is what makes the
guarantee actually hold when an agent is genuinely offline — which, for a
laptop-hosted agent, is most of the time.

## Reproduction

1. Pair a phone and open a project, so a push token is registered.
2. Close the project (or background the app) until `Peer offline: …<projectId>`
   appears in `~/.antgrid/host.log`, leaving only the control-plane connection.
3. Sign out in the app.
4. No `Cleared push token for phone …` line appears; the `pushToken` in
   `~/.antgrid/agents/paired-phones.json` is unchanged.

## Related

- `docs/issues/2026-07-20-orphaned-phone-row-on-keypair-rotation.md` — because
  sign-out also rotates the phone keypair, even a successful clear would land on
  a row that is about to be orphaned. Fix that one first; the two interact.
