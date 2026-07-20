import { z } from "zod/v4";

/**
 * Agent → relay control message carrying a sealed push blob. The relay is a
 * BLIND FORWARDER: it reads `pushToken` (opaque) and forwards `blob` (ciphertext)
 * to FCM. It never sees notification content. `box` is base64 of the AES-256-GCM
 * frame `nonce(12) ‖ ciphertext ‖ tag(16)`; `epk` is the base64 ephemeral X25519
 * public key used to derive the per-push key. Keep in lockstep with
 * bridge/src/push/seal.ts and packages/antgrid_relay_client/lib/src/e2e/push_open.dart.
 */
export const PushDeliverMessage = z.object({
  type: z.literal("push:deliver"),
  pushToken: z.string().min(1).max(4096),
  provider: z.literal("fcm"),
  blob: z.object({
    epk: z.string().min(1).max(256),
    box: z.string().min(1).max(8192),
  }),
});

export type PushDeliverMessage = z.infer<typeof PushDeliverMessage>;

/**
 * Relay → agent delivery result for a prior push:deliver. Plain z.object (no
 * id/timestamp) like every other ServerMessage. `reason` is present only when
 * `ok` is false: "unregistered" (FCM 404/410 — bridge clears the dead token),
 * "unconfigured" (relay has no FCM credential), or "error" (transient send
 * failure). Carries the opaque pushToken so the bridge maps the result back to
 * the phone whose token to prune (Task 7). Keep in lockstep with the relay
 * emitter in relay/src/server.ts and the consumer in bridge/src/relay-client.ts.
 */
export const PushResultMessage = z.object({
  type: z.literal("push:result"),
  pushToken: z.string(),
  ok: z.boolean(),
  reason: z.string().optional(),
});

export type PushResultMessage = z.infer<typeof PushResultMessage>;
