import type { PairedPhonesStore } from "../paired-phones";

/**
 * Clear a phone's FCM token after the relay reports it UNREGISTERED (FCM
 * 404/410). Matches by token because the relay's push:result carries only the
 * opaque token. Keeps `pushPubkey` — the persistent push identity is unchanged;
 * only the FCM token rotated, and the phone re-registers a fresh one on next
 * launch (Task 10).
 */
export function prunePushToken(pairedPhones: PairedPhonesStore, pushToken: string): void {
  const phone = pairedPhones.list().find((p) => p.pushToken === pushToken);
  if (!phone) return;
  pairedPhones.upsert({
    ...phone,
    pushToken: undefined,
    pushProvider: undefined,
    pushUpdatedAt: new Date().toISOString(),
  });
}
