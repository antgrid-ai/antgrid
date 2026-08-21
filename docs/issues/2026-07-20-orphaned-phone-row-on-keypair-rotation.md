# Sign-out orphans a paired-phone row, causing duplicate undecryptable pushes

**Status:** RESOLVED. `upsert` in `bridge/src/paired-phones.ts` now displaces by
`phoneDeviceId` as well as `phonePubkey`, so a rekeyed device replaces its row
instead of appending a second one. The open question this report left behind —
whether the old row's grants should carry across — was **resolved by removal**:
mobile authorization is one machine-level boolean (`mobile-access-policy.ts`) and
a phone row carries no grants to transfer. See Resolution.

**Found:** 2026-07-20, during Task 6 Step 10 of the `push`-package migration
(`feat/encrypted-push`, Android release build on device RZCW90YW9SY).

**Not a regression from the `push` migration.** The mechanism is in
`paired-phones.ts` / `project-core.ts` and behaves identically under
`firebase_messaging`. The migration's device pass is just the first time anyone
signed out and back in while watching the store.

## Symptom

After signing out and back in **without restarting the app**, the phone
re-registered its push token correctly — but into a *new* row, leaving the old
one intact. `~/.antgrid/agents/paired-phones.json` now holds two entries for one
physical device:

```
[21] phonePubkey cjrPKuy+…  pushToken(142)  pushPubkey(44)  pushUpdatedAt 14:04:16.982Z
[22] phonePubkey ohKWeJWV…  pushToken(142)  pushPubkey(44)  pushUpdatedAt 14:23:31.660Z
```

Comparing the two:

```
sameFcmToken     true
samePushPubkey   false
sameDeviceUuid   true
```

Same device, same live FCM token, **different push X25519 pubkey**.

## Root cause

`PairedPhonesStore` was keyed on `phonePubkey` throughout — `get`, `has` and
`remove` all take a pubkey; `phoneDeviceId` was carried but never used as an
identity. Sign-out wipes `flutter_secure_storage`, so
`PhoneIdentity.ensureKeypair` mints a fresh Ed25519 keypair on the next pair.
From the store's point of view that is simply a phone it has never seen, and
`upsert` appends.

Both rows were fully eligible push targets: at the time each carried its own
copy of the (since-deleted) per-phone project grants.

## Consequence

`resolveTargets` in `bridge/src/project-core.ts:355` falls back to **all** paired
phones when there is no live peer:

```ts
const candidates = peerPubkey ? paired.filter(p => p.phonePubkey === peerPubkey) : paired;
```

No live peer is precisely the push case. So a turn-end seals and delivers twice
(`push-dispatcher.ts:68`) to the same FCM token — once to the current push key,
once to a key the app discarded at sign-out. The device receives a duplicate
notification it cannot decrypt.

This compounds over time: every sign-out cycle adds another row, and every one
of them is a live push target.

`prunePushToken` will not clean this up. It fires only on an FCM
`UNREGISTERED` (404/410) and the token here is perfectly valid. Worse, it
matches with `.find((p) => p.pushToken === pushToken)` — with two rows sharing a
token it would clear only the first and leave the other armed.

## Resolution

Handled at registration, not at push: `upsert` displaces any row matching either
the incoming `phonePubkey` **or** its `phoneDeviceId`, so a rekey is a plain
replace. Machine-level trust is keyed on the device — two identities for one
`phoneDeviceId` is stale state by definition.

The "should the grants carry across?" question is moot. The union-carry that
merged the old row's `allowedProjects` into the new one is deleted along with the
field: a phone row is now identity, label, `lastSeenAt` and push credentials
only, and authorization is the machine-wide switch in `mobile-access-policy.ts`,
which a rekey never touches.

## Reproduction

1. Pair a phone, open a project, confirm `Registered push token for phone …` in
   `~/.antgrid/host.log`.
2. Sign out in the app. Sign back in **without restarting** the app.
3. Open a project again; a second `Registered push token` line appears.
4. Inspect `~/.antgrid/agents/paired-phones.json` — two rows share one
   `phoneDeviceId`.

## Related

- `docs/issues/2026-07-20-signout-push-clear-is-best-effort.md` — the sign-out
  clear that would otherwise have emptied the orphaned row.
