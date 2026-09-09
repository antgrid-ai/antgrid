import { Hono } from "hono";
import type { DB } from "../db/index.js";
import type { RelayPushConfig } from "../relay/push.js";
import { logPaddlePaymentFailure, PaddleProvider } from "../billing/paddle.js";
import { logRazorpayPaymentFailure, RazorpayProvider } from "../billing/razorpay.js";
import { applySubscriptionEvent } from "../billing/reducer.js";
import { hmacHexMatches } from "../util/hmac.js";
import { tokenBucket } from "../util/rate-limit.js";
import type { ClientIpResolver } from "../util/client-ip.js";
import {
  GITHUB_PROVIDER,
  GithubEnvelopeSchema,
  carriesPullRequest,
  isSubscribedGithubEvent,
} from "../integrations/github-events.js";
import { bodyDeliveryKey, recordDelivery } from "../integrations/webhook-events.js";

/**
 * Largest body accepted from GitHub, well under GitHub's own 25 MB ceiling.
 *
 * The endpoint is unauthenticated by construction — the signature is computed
 * from the body, so the body is read before anything is known about the caller —
 * and it writes to the database. Without a cap the handler buffers whatever
 * arrives and HMACs it at line rate. Two megabytes is two orders of magnitude
 * above the largest payload the App subscribes to: an `issues` event carries a
 * 64 KB body plus repository and installation metadata, and the widest
 * `installation` delivery is a repository list bounded by the schema.
 */
const MAX_GITHUB_BODY_BYTES = 2 * 1024 * 1024;

const SIGNATURE_PREFIX = "sha256=";

type CappedBody = { kind: "ok"; bytes: Uint8Array } | { kind: "too_large" };

/** Reads the body with a running ceiling rather than buffering it and measuring
 *  afterwards: a declared Content-Length is a claim, and a chunked request makes
 *  no claim at all. */
async function readCappedBody(req: Request, limit: number): Promise<CappedBody> {
  const declared = Number(req.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limit) return { kind: "too_large" };

  const stream = req.body;
  if (!stream) return { kind: "ok", bytes: new Uint8Array(0) };

  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      return { kind: "too_large" };
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { kind: "ok", bytes };
}

export function webhookRoutes(deps: {
  db: DB;
  relay: RelayPushConfig;
  clientIp: ClientIpResolver;
  paddleWebhookSecret?: string;
  razorpayWebhookSecret?: string;
  githubWebhookSecret?: string;
}) {
  const r = new Hono();
  // Per-IP. GitHub delivers in bursts when a repository is busy, so the capacity
  // is generous: the point is a ceiling on an unauthenticated flood, not a quota
  // on GitHub.
  const githubLimiter = tokenBucket(120, 20); // 120 burst, 20 per second, per IP

  r.post("/webhooks/paddle", async (c) => {
    if (!deps.paddleWebhookSecret) return c.json({ error: "PADDLE_NOT_CONFIGURED" }, 503);

    const provider = new PaddleProvider({ webhookSecret: deps.paddleWebhookSecret });
    const raw = await c.req.text();
    const signature = c.req.header("paddle-signature");

    let event;
    try {
      event = await provider.verifyWebhook(raw, signature);
    } catch {
      return c.json({ error: "INVALID_SIGNATURE" }, 400);
    }

    if (!event) {
      logPaddlePaymentFailure(raw);
      return c.json({ ok: true, ignored: true });
    }

    const parsed = JSON.parse(raw) as unknown;
    const result = await applySubscriptionEvent(deps.db, deps.relay, event, parsed);
    return c.json({ ok: true, duplicate: result.duplicate });
  });

  r.post("/webhooks/razorpay", async (c) => {
    if (!deps.razorpayWebhookSecret) return c.json({ error: "RAZORPAY_NOT_CONFIGURED" }, 503);

    const provider = new RazorpayProvider({ webhookSecret: deps.razorpayWebhookSecret });
    const raw = await c.req.text();
    const signature = c.req.header("x-razorpay-signature");

    let event;
    try {
      event = await provider.verifyWebhook(raw, signature);
    } catch {
      return c.json({ error: "INVALID_SIGNATURE" }, 400);
    }

    if (!event) {
      logRazorpayPaymentFailure(raw);
      return c.json({ ok: true, ignored: true });
    }

    const parsed = JSON.parse(raw) as unknown;
    const result = await applySubscriptionEvent(deps.db, deps.relay, event, parsed);
    return c.json({ ok: true, duplicate: result.duplicate });
  });

  /**
   * GitHub App deliveries: verify, record, 202. Nothing is applied here.
   *
   * The order of the first three steps is the security property, not a style:
   * the body is capped before it is read, the caller is rate-limited before the
   * HMAC runs, and the signature is checked over the RAW bytes before anything
   * parses them. Work happens later, in the drain — a webhook handler that does
   * its work before responding is a webhook handler that gets retried.
   */
  r.post("/webhooks/github", async (c) => {
    // 503 rather than accepting the delivery: an unverifiable body must never be
    // ingested because configuration is missing. GitHub retries, so a secret
    // added later loses nothing.
    if (!deps.githubWebhookSecret) return c.json({ error: "GITHUB_NOT_CONFIGURED" }, 503);

    const ip = deps.clientIp(c);
    if (!githubLimiter(`github-webhook:${ip ?? "unknown"}`)) {
      return c.json({ error: "RATE_LIMITED" }, 429);
    }

    const body = await readCappedBody(c.req.raw, MAX_GITHUB_BODY_BYTES);
    if (body.kind === "too_large") return c.json({ error: "PAYLOAD_TOO_LARGE" }, 413);

    const presented = c.req.header("x-hub-signature-256") ?? "";
    if (
      !presented.startsWith(SIGNATURE_PREFIX) ||
      !hmacHexMatches(
        deps.githubWebhookSecret,
        body.bytes,
        presented.slice(SIGNATURE_PREFIX.length)
      )
    ) {
      return c.json({ error: "INVALID_SIGNATURE" }, 401);
    }

    // Every header below this line is outside the signature. The event name only
    // routes; each handler re-validates the body it is handed.
    const event = c.req.header("x-github-event") ?? "";
    if (!isSubscribedGithubEvent(event)) {
      // `ping` on hook creation, and whatever GitHub adds next. A type we do not
      // subscribe to is a normal condition, and storing what nothing will ever
      // read is only growth.
      return c.json({ ok: true, ignored: true }, 202);
    }

    let parsedBody: unknown;
    try {
      parsedBody = JSON.parse(new TextDecoder().decode(body.bytes));
    } catch {
      return c.json({ error: "INVALID_JSON" }, 400);
    }

    const envelope = GithubEnvelopeSchema.safeParse(parsedBody);
    if (!envelope.success) return c.json({ error: "INVALID_PAYLOAD" }, 400);

    // GitHub models pull requests as issues and delivers them on the same
    // events; the only discriminator is the `pull_request` key. Filtered here as
    // well as in the import path, because a stored PR event is a row no phase
    // will ever apply.
    if (carriesPullRequest(parsedBody)) {
      return c.json({ ok: true, ignored: true }, 202);
    }

    const recorded = await recordDelivery(deps.db, {
      provider: GITHUB_PROVIDER,
      providerEventId: bodyDeliveryKey(body.bytes),
      type: event,
      payload: {
        // Not the dedup key — it is a header, outside the signed bytes, so one
        // captured (body, signature) pair replays for ever under fresh ids. Kept
        // because it is the only string GitHub's own delivery log is indexed by.
        deliveryId: c.req.header("x-github-delivery")?.slice(0, 200) ?? null,
        body: parsedBody,
      },
    });

    return c.json({ ok: true, duplicate: !recorded.inserted }, 202);
  });

  return r;
}
