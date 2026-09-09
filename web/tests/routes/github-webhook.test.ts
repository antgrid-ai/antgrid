import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { MAX_WEBHOOK_ATTEMPTS } from "../../src/integrations/webhook-events.js";

const SECRET = "github-app-webhook-secret-abcdefghij";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

function appWithSecret() {
  return buildTestApp(pg.db, pg.url, { envOverrides: { GITHUB_APP_WEBHOOK_SECRET: SECRET } });
}

function sign(raw: string, secret = SECRET): string {
  return `sha256=${createHmac("sha256", secret).update(raw).digest("hex")}`;
}

type DeliveryOpts = {
  event?: string;
  delivery?: string;
  signature?: string | null;
};

type TestApp = { fetch: (req: Request) => Response | Promise<Response> };

async function post(app: TestApp, raw: string, opts: DeliveryOpts = {}): Promise<Response> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "x-github-event": opts.event ?? "installation",
    "x-github-delivery": opts.delivery ?? "delivery-1",
  };
  const signature = opts.signature === undefined ? sign(raw) : opts.signature;
  if (signature !== null) headers["x-hub-signature-256"] = signature;
  return app.fetch(
    new Request("http://localhost/webhooks/github", { method: "POST", headers, body: raw })
  );
}

const installationBody = (action = "created") =>
  JSON.stringify({
    action,
    installation: { id: 42, account: { login: "acme" } },
    sender: { login: "someone" },
  });

async function rows() {
  return pg.db.webhookEvent.findMany({ orderBy: { receivedAt: "asc" } });
}

describe("POST /webhooks/github — signature", () => {
  test("a valid signature is accepted and recorded unprocessed", async () => {
    const { app } = appWithSecret();
    const raw = installationBody();
    const res = await post(app, raw, { delivery: "gh-abc" });
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ ok: true, duplicate: false });

    const stored = await rows();
    expect(stored).toHaveLength(1);
    expect(stored[0]!.provider).toBe("github");
    expect(stored[0]!.type).toBe("installation");
    expect(stored[0]!.processedAt).toBeNull();
    expect(stored[0]!.attempts).toBe(0);
    const payload = stored[0]!.payload as { deliveryId: string; body: { action: string } };
    expect(payload.deliveryId).toBe("gh-abc");
    expect(payload.body.action).toBe("created");
  });

  test("a wrong signature is rejected and writes nothing", async () => {
    const { app } = appWithSecret();
    const raw = installationBody();
    const res = await post(app, raw, { signature: sign(raw, "some-other-secret-value") });
    expect(res.status).toBe(401);
    expect(await rows()).toHaveLength(0);
  });

  test("a missing signature header is rejected", async () => {
    const { app } = appWithSecret();
    const res = await post(app, installationBody(), { signature: null });
    expect(res.status).toBe(401);
    expect(await rows()).toHaveLength(0);
  });

  test("a truncated signature is rejected without throwing", async () => {
    const { app } = appWithSecret();
    const raw = installationBody();
    const res = await post(app, raw, { signature: sign(raw).slice(0, 40) });
    expect(res.status).toBe(401);
  });

  // timingSafeEqual THROWS on unequal-length buffers, so a bare compare would
  // turn this header into a 500 — an attacker-controlled crash.
  test("a signature of the wrong length is rejected, not a 500", async () => {
    const { app } = appWithSecret();
    for (const digest of ["", "ab", "a".repeat(63), "a".repeat(65), "a".repeat(200)]) {
      const res = await post(app, installationBody(), { signature: `sha256=${digest}` });
      expect(res.status).toBe(401);
    }
  });

  test("a non-hex signature of the right length is rejected", async () => {
    const { app } = appWithSecret();
    const res = await post(app, installationBody(), { signature: `sha256=${"z".repeat(64)}` });
    expect(res.status).toBe(401);
  });

  test("a signature without the sha256= prefix is rejected", async () => {
    const { app } = appWithSecret();
    const raw = installationBody();
    const res = await post(app, raw, { signature: sign(raw).slice("sha256=".length) });
    expect(res.status).toBe(401);
  });

  test("an unconfigured secret answers 503 rather than accepting the delivery", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await post(app, installationBody());
    expect(res.status).toBe(503);
    expect(await rows()).toHaveLength(0);
  });
});

describe("POST /webhooks/github — idempotency", () => {
  // The reason the key is a hash of the signed bytes: X-GitHub-Delivery is a
  // header, so one captured (body, signature) pair replays for ever under fresh
  // ids if the header is trusted as the key.
  test("the same body replayed under a new delivery id is deduped", async () => {
    const { app } = appWithSecret();
    const raw = installationBody();

    const first = await post(app, raw, { delivery: "delivery-1" });
    expect(first.status).toBe(202);
    expect(await first.json()).toEqual({ ok: true, duplicate: false });

    const replay = await post(app, raw, { delivery: "delivery-2" });
    expect(replay.status).toBe(202);
    expect(await replay.json()).toEqual({ ok: true, duplicate: true });

    const stored = await rows();
    expect(stored).toHaveLength(1);
    const payload = stored[0]!.payload as { deliveryId: string };
    expect(payload.deliveryId).toBe("delivery-1");
  });

  test("two different bodies are two rows", async () => {
    const { app } = appWithSecret();
    await post(app, installationBody("created"));
    await post(app, installationBody("suspend"));
    expect(await rows()).toHaveLength(2);
  });

  test("redelivery of a failed row re-arms it", async () => {
    const { app } = appWithSecret();
    const raw = installationBody();
    await post(app, raw);

    const before = (await rows())[0]!;
    await pg.db.webhookEvent.update({
      where: { id: before.id },
      data: { attempts: 2, lastError: "boom" },
    });

    const res = await post(app, raw, { delivery: "redelivery" });
    expect(res.status).toBe(202);

    const after = (await rows())[0]!;
    expect(after.id).toBe(before.id);
    expect(after.attempts).toBe(3);
    expect(after.lastError).toBeNull();
    expect(after.processedAt).toBeNull();
  });

  test("redelivery of a row that gave up leaves it claimable again", async () => {
    const { app } = appWithSecret();
    const raw = installationBody();
    await post(app, raw);

    const before = (await rows())[0]!;
    await pg.db.webhookEvent.update({
      where: { id: before.id },
      data: { attempts: MAX_WEBHOOK_ATTEMPTS, lastError: "poison" },
    });

    await post(app, raw, { delivery: "redelivery" });

    const after = (await rows())[0]!;
    expect(after.attempts).toBeLessThan(MAX_WEBHOOK_ATTEMPTS);
    expect(after.lastError).toBeNull();
  });

  test("redelivery of a processed row leaves it untouched", async () => {
    const { app } = appWithSecret();
    const raw = installationBody();
    await post(app, raw);

    const processedAt = new Date("2026-01-01T00:00:00.000Z");
    const before = (await rows())[0]!;
    await pg.db.webhookEvent.update({
      where: { id: before.id },
      data: { attempts: 1, lastError: "dropped: unknown_installation", processedAt },
    });

    const res = await post(app, raw, { delivery: "redelivery" });
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ ok: true, duplicate: true });

    const after = (await rows())[0]!;
    expect(after.attempts).toBe(1);
    expect(after.lastError).toBe("dropped: unknown_installation");
    expect(after.processedAt?.toISOString()).toBe(processedAt.toISOString());
  });
});

describe("POST /webhooks/github — body handling", () => {
  test("an oversized body is refused with 413", async () => {
    const { app } = appWithSecret();
    const raw = JSON.stringify({ action: "created", filler: "x".repeat(3 * 1024 * 1024) });
    const res = await post(app, raw);
    expect(res.status).toBe(413);
    expect(await rows()).toHaveLength(0);
  });

  test("a signed body that is not JSON is refused with 400", async () => {
    const { app } = appWithSecret();
    const res = await post(app, "not json at all");
    expect(res.status).toBe(400);
    expect(await rows()).toHaveLength(0);
  });

  test("a signed body of the wrong shape is refused with 400", async () => {
    const { app } = appWithSecret();
    const res = await post(app, JSON.stringify(["not", "an", "object"]));
    expect(res.status).toBe(400);
    expect(await rows()).toHaveLength(0);
  });

  test("a NUL inside the body is stored, not a 500 the provider redelivers into", async () => {
    const { app } = appWithSecret();
    const nul = String.fromCharCode(0);
    const raw = JSON.stringify({
      action: "created",
      installation: { id: 42, account: { login: `ac${nul}me` } },
      sender: { login: "someone" },
    });
    const res = await post(app, raw);
    expect(res.status).toBe(202);

    const stored = await rows();
    expect(stored).toHaveLength(1);
    const payload = stored[0]!.payload as {
      body: { installation: { account: { login: string } } };
    };
    expect(payload.body.installation.account.login).toBe("acme");
  });
});

describe("POST /webhooks/github — event types", () => {
  test("an event type we do not subscribe to is ignored, not an error", async () => {
    const { app } = appWithSecret();
    for (const event of ["ping", "push", "star", ""]) {
      const res = await post(app, installationBody(), { event });
      expect(res.status).toBe(202);
      expect(await res.json()).toEqual({ ok: true, ignored: true });
    }
    expect(await rows()).toHaveLength(0);
  });

  // 4c turns these on by moving the type into GITHUB_HANDLED_EVENTS; recording
  // them now is what makes that a small change rather than a lost backlog.
  test("issues, issue_comment and label are recorded and left unprocessed", async () => {
    const { app } = appWithSecret();
    const bodies = {
      issues: JSON.stringify({
        action: "opened",
        installation: { id: 42 },
        issue: { number: 1, title: "t" },
      }),
      issue_comment: JSON.stringify({
        action: "created",
        installation: { id: 42 },
        issue: { number: 1 },
        comment: { id: 9 },
      }),
      label: JSON.stringify({ action: "created", installation: { id: 42 }, label: { id: 3 } }),
    };
    for (const [event, raw] of Object.entries(bodies)) {
      const res = await post(app, raw, { event });
      expect(res.status).toBe(202);
    }
    const stored = await rows();
    expect(stored.map((r) => r.type).sort()).toEqual(["issue_comment", "issues", "label"]);
    expect(stored.every((r) => r.processedAt === null)).toBe(true);
  });

  test("an issues payload for a pull request is dropped at the door", async () => {
    const { app } = appWithSecret();
    const raw = JSON.stringify({
      action: "opened",
      installation: { id: 42 },
      issue: { number: 7, title: "a PR", pull_request: { url: "https://api.github.com/pulls/7" } },
    });
    const res = await post(app, raw, { event: "issues" });
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ ok: true, ignored: true });
    expect(await rows()).toHaveLength(0);
  });
});

describe("POST /webhooks/github — rate limit", () => {
  test("a flood from one caller is refused with 429", async () => {
    const { app } = appWithSecret();
    // Unsigned: the limiter runs before the HMAC, so a rejected delivery still
    // costs a token — which is the whole point of limiting an unauthenticated
    // endpoint.
    let limited = 0;
    for (let i = 0; i < 200; i++) {
      const res = await post(app, installationBody(), { signature: null });
      if (res.status === 429) limited++;
    }
    expect(limited).toBeGreaterThan(0);
    expect(await rows()).toHaveLength(0);
  });
});
