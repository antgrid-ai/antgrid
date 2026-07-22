import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";

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

type CapturedEmail = { to: string; subject: string; text: string; html?: string };

function makeCapture(): { captured: CapturedEmail[]; sendEmail: (a: CapturedEmail) => Promise<void> } {
  const captured: CapturedEmail[] = [];
  return {
    captured,
    sendEmail: async (a) => {
      captured.push(a);
    },
  };
}

describe("cross-device sign-in end-to-end", () => {
  test("start → approve in second client → poll returns ready + session cookie", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      usePrismaAdapter: true,
    });

    // 1. Browser A submits the email form.
    const startRes = await app.fetch(
      new Request("http://localhost/ui/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          "user-agent": "browserA/1",
          "x-forwarded-for": "1.1.1.1",
        },
        body: "email=alice@example.com",
      })
    );
    expect(startRes.status).toBe(302);
    const browserACookieHeader = startRes.headers.get("set-cookie") ?? "";
    expect(browserACookieHeader).toContain("antgrid.cross_device_token=");
    expect(cap.captured.length).toBe(1);
    expect(cap.captured[0].to).toBe("alice@example.com");
    // The requester UA + IP must survive the api.* hop (regression: they were
    // read from ctx.request, which is undefined on programmatic calls).
    expect(cap.captured[0].text).toContain("browserA/1");
    expect(cap.captured[0].text).toContain("1.1.1.1");

    // 2. Extract id + token from the email body.
    const url = cap.captured[0].text.match(/https?:\/\/[^\s]+/)![0];
    const u = new URL(url);
    const id = u.searchParams.get("id")!;
    const token = u.searchParams.get("t")!;
    expect(id).toBeTruthy();
    expect(token).toBeTruthy();

    // 3. Browser B approves (no Browser A cookie).
    const approveRes = await app.fetch(
      new Request("http://localhost/ui/login/approve", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: `id=${id}&token=${token}`,
      })
    );
    expect(approveRes.status).toBe(302);
    expect(approveRes.headers.get("location")).toBe("/login/approved");

    // 4. Browser A polls — must carry its binding cookie.
    const browserACookie = browserACookieHeader.split(";")[0];
    const pollRes = await app.fetch(
      new Request(`http://localhost/ui/login/poll/${id}`, {
        method: "GET",
        headers: { cookie: browserACookie },
      })
    );
    expect(pollRes.headers.get("hx-redirect")).toBe("/dashboard");
    const sessionCookieHeader = pollRes.headers.get("set-cookie") ?? "";
    expect(sessionCookieHeader).toContain("better-auth.session_token=");

    // 5. /dashboard with the session cookie returns 200.
    // Extract just the session_token cookie pair (set-cookie may include multiple cookies, comma-separated).
    const sessionMatch = sessionCookieHeader.match(/better-auth\.session_token=[^;,]+/);
    expect(sessionMatch).not.toBeNull();
    const sessionCookie = sessionMatch![0];
    const dashRes = await app.fetch(
      new Request("http://localhost/dashboard", {
        headers: { cookie: sessionCookie },
      })
    );
    expect(dashRes.status).toBe(200);
  });

  test("poll without cookie returns 'unbound' (no session leak)", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      usePrismaAdapter: true,
    });

    const startRes = await app.fetch(
      new Request("http://localhost/ui/login/start", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "email=eve@example.com",
      })
    );
    expect(startRes.status).toBe(302);

    const url = cap.captured.at(-1)!.text.match(/https?:\/\/[^\s]+/)![0];
    const u = new URL(url);
    const id = u.searchParams.get("id")!;
    const token = u.searchParams.get("t")!;

    await app.fetch(
      new Request("http://localhost/ui/login/approve", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: `id=${id}&token=${token}`,
      })
    );

    const pollRes = await app.fetch(
      new Request(`http://localhost/ui/login/poll/${id}`)
    );
    // No cookie → status "unbound" → HX-Redirect to /login error.
    expect(pollRes.headers.get("hx-redirect")).toContain("Link%20expired");
    // No session cookie should be set on this response.
    expect(pollRes.headers.get("set-cookie") ?? "").not.toContain(
      "better-auth.session_token="
    );
  });

  test("approve with wrong token redirects to /login error", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      usePrismaAdapter: true,
    });

    await app.fetch(
      new Request("http://localhost/ui/login/start", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "email=mallory@example.com",
      })
    );

    const url = cap.captured.at(-1)!.text.match(/https?:\/\/[^\s]+/)![0];
    const id = new URL(url).searchParams.get("id")!;

    const res = await app.fetch(
      new Request("http://localhost/ui/login/approve", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: `id=${id}&token=garbage`,
      })
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toContain("Could%20not%20approve");
  });

  test("double-submitted approve is idempotent — the duplicate reports success", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      usePrismaAdapter: true,
    });

    await app.fetch(
      new Request("http://localhost/ui/login/start", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "email=dave@example.com",
      })
    );

    const url = cap.captured.at(-1)!.text.match(/https?:\/\/[^\s]+/)![0];
    const u = new URL(url);
    const id = u.searchParams.get("id")!;
    const token = u.searchParams.get("t")!;

    const submit = () =>
      app.fetch(
        new Request("http://localhost/ui/login/approve", {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: `id=${id}&token=${token}`,
        })
      );

    const first = await submit();
    expect(first.headers.get("location")).toBe("/login/approved");

    // A double-clicked button re-POSTs the same form. The approval already
    // succeeded, so the duplicate must report success rather than an error the
    // user cannot act on.
    const second = await submit();
    expect(second.status).toBe(302);
    expect(second.headers.get("location")).toBe("/login/approved");
  });

  test("re-clicking the emailed link after approving reports success", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      usePrismaAdapter: true,
    });

    await app.fetch(
      new Request("http://localhost/ui/login/start", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "email=frank@example.com",
      })
    );

    const url = cap.captured.at(-1)!.text.match(/https?:\/\/[^\s]+/)![0];
    const u = new URL(url);
    const id = u.searchParams.get("id")!;
    const token = u.searchParams.get("t")!;

    await app.fetch(
      new Request("http://localhost/ui/login/approve", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: `id=${id}&token=${token}`,
      })
    );

    // Re-opening the link — back button, a second tap, a mail client that
    // prefetches URLs — must not accuse the user of reusing a dead link for an
    // approval that in fact succeeded.
    const reclick = await app.fetch(
      new Request(`http://localhost/login/approve?id=${id}&t=${token}`)
    );
    expect(reclick.status).toBe(302);
    expect(reclick.headers.get("location")).toBe("/login/approved");
  });

  test("approval state is not disclosed to a caller without the token", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      usePrismaAdapter: true,
    });

    await app.fetch(
      new Request("http://localhost/ui/login/start", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "email=grace@example.com",
      })
    );

    const url = cap.captured.at(-1)!.text.match(/https?:\/\/[^\s]+/)![0];
    const u = new URL(url);
    const id = u.searchParams.get("id")!;
    const token = u.searchParams.get("t")!;

    const probe = () =>
      app.fetch(new Request(`http://localhost/login/approve?id=${id}&t=wrong`));

    // Someone who learns the row id but not the nonce must not be able to tell
    // whether the victim has approved — the reply has to read the same either
    // side of the approval.
    const before = (await probe()).headers.get("location");

    await app.fetch(
      new Request("http://localhost/ui/login/approve", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: `id=${id}&token=${token}`,
      })
    );

    const after = (await probe()).headers.get("location");
    expect(after).toBe(before);
    expect(after).toBe("/login?error=Invalid%20link");
  });

  test("approve double-submit still lets Browser A poll a session", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      usePrismaAdapter: true,
    });

    const startRes = await app.fetch(
      new Request("http://localhost/ui/login/start", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "email=erin@example.com",
      })
    );
    const browserACookie = (startRes.headers.get("set-cookie") ?? "").split(";")[0];

    const url = cap.captured.at(-1)!.text.match(/https?:\/\/[^\s]+/)![0];
    const u = new URL(url);
    const id = u.searchParams.get("id")!;
    const token = u.searchParams.get("t")!;

    for (let i = 0; i < 2; i++) {
      await app.fetch(
        new Request("http://localhost/ui/login/approve", {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: `id=${id}&token=${token}`,
        })
      );
    }

    const pollRes = await app.fetch(
      new Request(`http://localhost/ui/login/poll/${id}`, {
        headers: { cookie: browserACookie },
      })
    );
    expect(pollRes.headers.get("hx-redirect")).toBe("/dashboard");
    expect(pollRes.headers.get("set-cookie") ?? "").toContain(
      "better-auth.session_token="
    );
  });

  test("status endpoint surfaces a bounce after a webhook marks the row", async () => {
    const cap = makeCapture();
    const KEY = "webhook-secret-key-abcdefghij";
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      envOverrides: { ZEPTOMAIL_WEBHOOK_SECRET: KEY } as any,
    });

    // Start via the app-facing endpoint to get the bind cookie + row id.
    const startRes = await app.fetch(new Request(
      "http://localhost/api/auth/sign-in/cross-device/start", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: "bob@example.com" }),
      }));
    expect(startRes.status).toBe(200);
    const { id } = (await startRes.json()) as { id: string };
    const bind = (startRes.headers.get("set-cookie") ?? "")
      .match(/antgrid\.cross_device_token=([^;,]+)/)![1];

    // Webhook reports a hard bounce for that row (client_reference == id).
    const hook = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        event_name: ["hardbounce"],
        event_message: [{ email_info: { client_reference: id } }],
      }),
    }));
    expect(hook.status).toBe(200);

    // Poll (still pending — not yet approved) now carries the bounce.
    const statusRes = await app.fetch(new Request(
      "http://localhost/api/auth/sign-in/cross-device/status", {
        headers: { cookie: `antgrid.cross_device_token=${bind}` },
      }));
    const statusBody = (await statusRes.json()) as { status: string; delivery?: string | null };
    expect(statusBody.status).toBe("pending");
    expect(statusBody.delivery).toBe("bounced");
  });

  test("web login poll stops and redirects on a hard bounce", async () => {
    const cap = makeCapture();
    const KEY = "webhook-secret-key-abcdefghij";
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail: cap.sendEmail,
      usePrismaAdapter: true,
      envOverrides: { ZEPTOMAIL_WEBHOOK_SECRET: KEY } as any,
    });

    // Browser A starts via the HTMX login form; capture its bind cookie + row id.
    const startRes = await app.fetch(new Request("http://localhost/ui/login/start", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "email=bounce@example.com",
    }));
    expect(startRes.status).toBe(302);
    const cookie = (startRes.headers.get("set-cookie") ?? "").split(";")[0];
    const id = startRes.headers.get("location")!.match(/\/login\/pending\/([0-9a-f-]+)/)![1];

    // The magic-link email hard-bounces for that row.
    const hook = await app.fetch(new Request(`http://localhost/webhooks/zeptomail/${KEY}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ event_name: ["hardbounce"], event_message: [{ email_info: { client_reference: id } }] }),
    }));
    expect(hook.status).toBe(200);

    // Browser A's next poll must stop (HX-Redirect), not re-render "Waiting…".
    const pollRes = await app.fetch(new Request(`http://localhost/ui/login/poll/${id}`, {
      headers: { cookie },
    }));
    expect(pollRes.headers.get("hx-redirect")).toContain("deliver");
  });
});
