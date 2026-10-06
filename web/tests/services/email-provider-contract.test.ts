// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterEach, expect, test } from "bun:test";
import { createEmailSender, EmailProviderError } from "../../src/auth/email.js";

const originalFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = originalFetch; });

test("ZeptoMail contract disables tracking, preserves references, and captures acceptance", async () => {
  let request: RequestInit | undefined;
  globalThis.fetch = (async (_url: unknown, init?: RequestInit) => {
    request = init;
    return Response.json({ data: [{ code: "EM_104", message: "OK" }], request_id: "provider-request" });
  }) as unknown as typeof fetch;
  const send = createEmailSender({ zeptoToken: "Zoho-enczapikey configured", from: "Antgrid <no-reply@antgrid.ai>", replyTo: "contact@radhaai.com" });
  expect(await send({ to: "owner@example.com", subject: "Review", text: "plain", html: "<p>Review</p>", clientReference: "job-reference" })).toEqual({ providerId: "provider-request" });
  expect(JSON.parse(String(request!.body))).toMatchObject({ track_opens: false, track_clicks: false, client_reference: "job-reference", textbody: "plain", htmlbody: "<p>Review</p>", reply_to: [{ address: "contact@radhaai.com" }] });
  expect(new Headers(request!.headers).get("authorization")).toBe("Zoho-enczapikey configured");
  expect(request!.signal).toBeInstanceOf(AbortSignal);
});

test("provider failures expose only classified, sanitized errors and retry timing", async () => {
  const send = createEmailSender({ zeptoToken: "configured", from: "Antgrid <no-reply@antgrid.ai>" });
  for (const [status,kind] of [[400,"permanent"],[401,"configuration"],[403,"configuration"],[429,"transient"],[503,"transient"]] as const) {
    globalThis.fetch = (async () => new Response("secret-recipient@example.com https://antgrid.ai/token", { status, headers: { "retry-after": "90" } })) as unknown as typeof fetch;
    let error: unknown;
    try { await send({ to: "owner@example.com", subject: "Review", text: "private" }); } catch (caught) { error = caught; }
    expect(error).toBeInstanceOf(EmailProviderError);
    expect((error as EmailProviderError).kind).toBe(kind);
    expect((error as EmailProviderError).retryAfter).toBe(90);
    expect(String(error)).not.toContain("secret-recipient");
    expect(String(error)).not.toContain("/token");
  }
});

test("unverified sender and account credit failures pause instead of discarding valid jobs", async () => {
  const send = createEmailSender({ zeptoToken: "configured",from: "Antgrid <no-reply@antgrid.ai>" });
  for (const code of ["SM_111","SERR_157","LE_102"]) {
    globalThis.fetch = (async () => Response.json({ error: { code: "TM_4001",details: [{ code,message: "sensitive" }] } },{ status: 400 })) as unknown as typeof fetch;
    let failure: unknown;
    try { await send({ to: "owner@example.com",subject: "Review",text: "private" }); } catch (error) { failure=error; }
    expect((failure as EmailProviderError).kind).toBe("configuration");
  }
});
