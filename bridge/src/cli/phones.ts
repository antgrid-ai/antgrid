import { loadRemoteAccessPolicy } from "../remote-access-policy";
import type { PairedPhonesStore, PairedPhone } from "../paired-phones";

/** Find a phone by pubkey, deviceId, or label. Returns null if 0 or >1 match. */
function findPhone(store: PairedPhonesStore, ref: string): PairedPhone | null {
  const phones = store.list();
  const matches = phones.filter(
    (p) => p.phonePubkey === ref || p.phoneDeviceId === ref || p.label === ref,
  );
  return matches.length === 1 ? matches[0] : null;
}

export function phonesList(store: PairedPhonesStore): number {
  for (const p of store.list()) {
    // Rows are read back without field validation, so a hand-edited file can
    // omit lastSeenAt — print "unknown", never the string "undefined".
    const lastSeen = p.lastSeenAt || "unknown";
    console.log(`${p.label ?? p.phoneDeviceId}  [${p.phoneDeviceId}]  last seen: ${lastSeen}`);
  }
  return 0;
}

/**
 * Drop a phone's local record.
 *
 * This is NOT a revocation. Admission is decided in `relay-client.ts`
 * (`handleClientHello`) by `verifyTranscriptSig` against the account inventory,
 * and that path re-creates the row on the phone's very next hello. What removal
 * actually clears is the local bookkeeping — label, `lastSeenAt`, and the push
 * pubkey/token, so push delivery stops until the phone re-registers. Cutting a
 * phone off means turning this machine's mobile-access switch off (machine-wide,
 * every phone) or signing the device out of the account.
 */
export function phonesRemove(
  store: PairedPhonesStore,
  phoneRef: string,
  abDir: string,
): number {
  // Run the mobile-access v1→v2 migration before the flush below, not after:
  // that migration derives the machine switch partly from the `allowedProjects`
  // still sitting in paired-phones.json, and every flush sheds them. Running
  // this CLI once on a new build before the first new-host start would
  // otherwise have the migration see no grants → switch off, silently revoking
  // mobile access for anyone who granted through `antgrid phones allow`.
  // Loading the phones store is safe ahead of this (it never writes at load).
  loadRemoteAccessPolicy(abDir);

  const phone = findPhone(store, phoneRef);
  if (!phone) { console.error(`phone not found (or ambiguous): ${phoneRef}`); return 2; }
  store.remove(phone.phonePubkey);
  console.log(`removed ${phone.label ?? phone.phoneDeviceId}`);
  console.error(
    "note: this clears the local record only (label, last seen, push token) — it does not revoke " +
      "access. An account-trusted phone re-registers on its next connection. To cut mobile access " +
      "off, disable mobile access for this machine (all phones) or sign the device out of the account.",
  );
  return 0;
}
