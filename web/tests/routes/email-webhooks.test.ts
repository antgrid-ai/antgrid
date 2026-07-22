import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createPending, findByIdWithHashes } from "../../src/models/pending-sign-in.js";
import { TEST_BETTER_AUTH_SECRET } from "../helpers/app.js";

const KEY = "webhook-secret-key-abcdefghij";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

function appWithSecret() {
  return buildTestApp(pg.db, pg.url, { envOverrides: { ZEPTOMAIL_WEBHOOK_SECRET: KEY } as any });
}

// ZeptoMail wraps event_name/event_message in arrays — mirror the real shape
// so these tests exercise the array-unwrapping path in extractRef/classify.
function bouncePayload(clientReference: string) {
  return {
    event_name: ["hardbounce"],
    event_message: [{ email_info: { client_reference: clientReference, to: "a@example.com" } }],
  };
}

function eventPayload(eventName: string, clientReference: string) {
  return {
    event_name: [eventName],
    event_message: [{ email_info: { client_reference: clientReference, to: "a@example.com" } }],
  };
}

describe("POST /webhooks/zeptomail/:key", () => {
  test("hard bounce marks the correlated row bounced", async () => {
    const { app } = appWithSecret();
    const row = await createPending(pg.db, {
      email: "a@example.com", nonce: "n", browserToken: "b",
      secret: TEST_BETTER_AUTH_SECRET, requesterUa: null, requesterIp: null,
    });
    const res = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(bouncePayload(row.id)),
    }));
    expect(res.status).toBe(200);
    const after = await findByIdWithHashes(pg.db, row.id);
    expect(after?.deliveryStatus).toBe("bounced");
  });

  test("wrong key is rejected 401 and mutates nothing", async () => {
    const { app } = appWithSecret();
    const row = await createPending(pg.db, {
      email: "a@example.com", nonce: "n", browserToken: "b",
      secret: TEST_BETTER_AUTH_SECRET, requesterUa: null, requesterIp: null,
    });
    const res = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/wrong-key`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(bouncePayload(row.id)),
    }));
    expect(res.status).toBe(401);
    const after = await findByIdWithHashes(pg.db, row.id);
    expect(after?.deliveryStatus).toBeNull();
  });

  test("a non-bounce event (soft bounce) is ignored, not recorded", async () => {
    const { app } = appWithSecret();
    const row = await createPending(pg.db, {
      email: "a@example.com", nonce: "n", browserToken: "b",
      secret: TEST_BETTER_AUTH_SECRET, requesterUa: null, requesterIp: null,
    });
    // softbounce is transient (retryable) — only a hard bounce is actionable, so
    // this must leave deliveryStatus null. ZeptoMail sends no "delivered" event.
    const res = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(eventPayload("softbounce", row.id)),
    }));
    expect(res.status).toBe(200);
    const after = await findByIdWithHashes(pg.db, row.id);
    expect(after?.deliveryStatus).toBeNull();
  });

  test("tolerates a bare (non-array) payload without crashing", async () => {
    const { app } = appWithSecret();
    const row = await createPending(pg.db, {
      email: "a@example.com", nonce: "n", browserToken: "b",
      secret: TEST_BETTER_AUTH_SECRET, requesterUa: null, requesterIp: null,
    });
    const res = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      // ZeptoMail sends arrays, but the parser also accepts the bare form so a
      // hand-crafted/legacy payload can't throw before the 200.
      body: JSON.stringify({
        event_name: "hardbounce",
        event_message: { email_info: { client_reference: row.id } },
      }),
    }));
    expect(res.status).toBe(200);
    const after = await findByIdWithHashes(pg.db, row.id);
    expect(after?.deliveryStatus).toBe("bounced");
  });

  test("parses a live-shaped ZeptoMail hardbounce payload (extra fields ignored)", async () => {
    const { app } = appWithSecret();
    const row = await createPending(pg.db, {
      email: "a@example.com", nonce: "n", browserToken: "b",
      secret: TEST_BETTER_AUTH_SECRET, requesterUa: null, requesterIp: null,
    });
    // Verbatim shape of a real ZeptoMail hardbounce webhook — the surrounding
    // cc/bcc/event_data/*_id fields must not disturb reading event_name[0] and
    // event_message[0].email_info.client_reference.
    const payload = {
      event_name: ["hardbounce"],
      event_message: [
        {
          email_info: {
            client_reference: row.id,
            subject: "webhook test email",
            from: { address: "webhooktest@zylker.com", name: "webhooktest" },
            to: [{ email_address: { address: "bouncerecipient@zylker.com", name: "BounceRecipient" } }],
            processed_time: "2026-07-09T06:11:57Z",
            object: "email",
          },
          event_data: [
            {
              details: [{ reason: "relaying-issues", bounced_recipient: "bouncerecipient@zylker.com", diagnostic_message: "bad-mailbox" }],
              object: "hardbounce",
            },
          ],
          request_id: "2d6f.4e459d13755d6198.m1.abc",
        },
      ],
      mailagent_key: "2d6f.4e459d13755d6198.47e48af28e9887a5",
      webhook_request_id: "2d6f.4e459d13755d6198.w1.def",
    };
    const res = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    }));
    expect(res.status).toBe(200);
    const after = await findByIdWithHashes(pg.db, row.id);
    expect(after?.deliveryStatus).toBe("bounced");
  });

  test("a hard bounce with no client_reference returns 200 and records nothing", async () => {
    const { app } = appWithSecret();
    // extractRef → null (email_info carries no client_reference). The handler
    // must not 500 and must mark nothing; it logs a breadcrumb (hasRef=false) so
    // the correlation failure is visible rather than a silent no-op.
    const res = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ event_name: ["hardbounce"], event_message: [{ email_info: {} }] }),
    }));
    expect(res.status).toBe(200);
  });

  test("a non-string event_name does not crash the handler", async () => {
    const { app } = appWithSecret();
    // A hand-crafted payload with a numeric event_name must not throw in
    // eventName() — the handler stays a clean 200 instead of a retryable 500.
    const res = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ event_name: [123], event_message: [{ email_info: { client_reference: "x" } }] }),
    }));
    expect(res.status).toBe(200);
  });

  test("unknown reference returns 200 without error", async () => {
    const { app } = appWithSecret();
    const res = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(bouncePayload("11111111-1111-1111-1111-111111111111")),
    }));
    expect(res.status).toBe(200);
  });
});
