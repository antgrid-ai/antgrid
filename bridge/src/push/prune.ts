import type { PairedPhonesStore } from "../paired-phones";
import { logger } from "../logger";
const log = logger.child({ component: "push-prune" });

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
  // warn: this disarms push for the phone until the app re-registers a token.
  // Unlogged, the dispatcher just goes quiet and host.log offers no reason.
  log.warn(
    "push: token for phone %s reported dead — cleared; push stays off until the app re-registers",
    phone.label ?? phone.phoneDeviceId,
  );
  pairedPhones.upsert({
    ...phone,
    pushToken: undefined,
    pushProvider: undefined,
    pushUpdatedAt: new Date().toISOString(),
  });
}
