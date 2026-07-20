import type { AbMessage } from "../protocol";
import { composePush } from "./compose";

const MAX_BODY_LEN = 480; // keep the sealed payload well under FCM's ~4 KB data cap

export interface PushTarget {
  pushToken: string;
  provider: "fcm";
  pushPubkey: string;
}

export interface PushDispatcherDeps {
  projectId: string;
  /** True when the phone can't receive in-band and a fallback push should fire.
   *  This is the SUPPRESSION union (peer offline OR app backgrounded), not bare
   *  peer-offline — a connected-but-backgrounded phone (Phase 1) must still push. */
  shouldFallback: () => boolean;
  resolveTarget: () => PushTarget | null;
  seal: (json: string, recipientPushPubkeyB64: string) => { epk: string; box: string };
  deliver: (token: string, provider: "fcm", blob: { epk: string; box: string }) => void;
}

/**
 * Observes OUTBOUND user-facing messages and, when the paired phone can't
 * receive in-band (relay socket offline OR app backgrounded — the suppression
 * union), seals a notification payload to the phone's persistent push key and
 * hands the ciphertext to the relay (via deps.deliver → push:deliver). The live
 * in-band path handles the not-suppressed case, so we no-op then.
 */
export function createPushDispatcher(deps: PushDispatcherDeps) {
  return {
    onOutbound(msg: AbMessage): void {
      const composed = composePush(msg);
      if (!composed) return;
      if (!deps.shouldFallback()) return;
      const target = deps.resolveTarget();
      if (!target) return;
      const sourceMessageId = msg.type === "handler:escalation" ? msg.escalationId : msg.id;
      const payload = JSON.stringify({
        title: composed.title,
        body: composed.body.slice(0, MAX_BODY_LEN),
        kind: composed.kind,
        projectId: deps.projectId,
        sourceMessageId,
      });
      const blob = deps.seal(payload, target.pushPubkey);
      deps.deliver(target.pushToken, target.provider, blob);
    },
  };
}
