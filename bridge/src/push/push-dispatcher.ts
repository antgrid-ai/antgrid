import type { AbMessage } from "../protocol";
import { logger } from "../logger";
const log = logger.child({ component: "push-dispatcher" });
import { composePush } from "./compose";

const MAX_BODY_LEN = 480; // keep the sealed payload well under FCM's ~4 KB data cap
// The title is a session name (protocol.ts SessionEntry), which nothing upstream
// bounds. Oversizing it is silent data loss, not a truncated toast: the relay Zod-
// rejects a `box` over 8192 base64 chars before forwarding, and a rejected deliver
// produces no push:result, so the notification simply never exists.
const MAX_TITLE_LEN = 120;

export interface PushTarget {
  pushToken: string;
  provider: "fcm" | "apns";
  pushPubkey: string;
}

export interface PushDispatcherDeps {
  projectId: string;
  /** True when the phone can't receive in-band and a fallback push should fire.
   *  This is the SUPPRESSION union (peer offline OR app backgrounded), not bare
   *  peer-offline — a connected-but-backgrounded phone must still push. */
  shouldFallback: () => boolean;
  /** The phones eligible to receive this notification; empty means nowhere to
   *  send. Plural because with no live peer the agent can't know which allowed
   *  device the user holds — see resolveTargets in project-core.ts. */
  resolveTargets: () => PushTarget[];
  /** The bare machine deviceUuid this host registers under. A getter because the
   *  two suppliers differ in how well they can answer: host-server reads the live
   *  machine socket's identity, while the wizard-promotion path can only report
   *  the uuid the enabling `agent:enableRelay` carried (see relay-promotion.ts). */
  machineUuid: () => string;
  seal: (json: string, recipientPushPubkeyB64: string) => { epk: string; box: string };
  deliver: (token: string, provider: "fcm" | "apns", blob: { epk: string; box: string }) => void;
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
      // Past this point every return path drops a user-facing notification, and
      // each one is otherwise indistinguishable from "the agent never notified".
      // Log at most one line per notification (composePush already filtered the
      // firehose down to notification:push / handler:escalation).
      if (!deps.shouldFallback()) {
        // info, not debug: this is the ONLY signal that a notification existed
        // at all. At debug it's indistinguishable from the agent never notifying,
        // which sends anyone debugging push off hunting a message that was in
        // fact delivered in-band. One line per turn on a relay-paired project.
        log.info("push: %s not sent — phone can receive in-band", composed.kind);
        return;
      }
      const targets = deps.resolveTargets();
      if (targets.length === 0) {
        // warn: the phone can't receive in-band AND has nowhere to push, so this
        // notification is lost outright. resolveTargets logs the specific cause.
        log.warn("push: %s DROPPED — no push target for project %s", composed.kind, deps.projectId);
        return;
      }
      const payload = JSON.stringify({
        title: composed.title.slice(0, MAX_TITLE_LEN),
        body: composed.body.slice(0, MAX_BODY_LEN),
        kind: composed.kind,
        projectId: deps.projectId,
        // projectId is sha256(realpath(folder)) with no machine input, so two
        // machines holding the same repo at the same path mint the identical id.
        machineUuid: deps.machineUuid(),
        ...(composed.terminalId ? { terminalId: composed.terminalId } : {}),
        sourceMessageId: composed.sourceMessageId,
      });
      // Seal per target: each phone has its own push key, so the ciphertext can't
      // be shared even though the plaintext is identical.
      for (const target of targets) {
        const blob = deps.seal(payload, target.pushPubkey);
        deps.deliver(target.pushToken, target.provider, blob);
      }
      log.info(
        "push: %s sealed and handed to relay (providers=%s)",
        composed.kind,
        targets.map((t) => t.provider).join(","),
      );
    },
  };
}
