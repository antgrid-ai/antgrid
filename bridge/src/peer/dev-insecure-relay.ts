import { peerAuthorizationSnapshotSchema } from "antgrid-wire";
import { logger } from "../logger";

/**
 * Dev-only: accept a plaintext `http://` Iroh relay origin, for the local stack
 * that has no DNS name or publicly trusted certificate (`aspire/peer-stack.ts`).
 *
 * Read from this machine's own environment exactly once, and never from an
 * authorization snapshot: the whole point of the scheme check is that a backend
 * answering with an `http:` origin must not be able to downgrade this host's
 * transport, so the decision has to originate locally.
 */
export const DEV_INSECURE_RELAY = process.env.ANTGRID_DEV_INSECURE_RELAY === "true";

if (DEV_INSECURE_RELAY) {
  logger.warn("ANTGRID_DEV_INSECURE_RELAY is set: plaintext Iroh relay origins are accepted");
}

/** Snapshot schema this host will accept, TLS-only unless the dev flag is set. */
export const AcceptedAuthorizationSnapshotSchema =
  peerAuthorizationSnapshotSchema(DEV_INSECURE_RELAY);
