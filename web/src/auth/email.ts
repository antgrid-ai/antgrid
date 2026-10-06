// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

export class EmailProviderError extends Error {
  constructor(public kind: "transient" | "permanent" | "configuration", public retryAfter?: number) { super(`Email provider ${kind} failure`); }
}
export type SendEmail = (args: {
  to: string;
  subject: string;
  text: string;
  html?: string;
  clientReference?: string;
  expiresAt?: Date;
}) => Promise<void | { providerId?: string }>;

// ZeptoMail is region-pinned; this host serves the global/US data center. If the
// account/domain is verified in another region (.eu/.in/.com.cn), change it here.
const ZEPTOMAIL_ENDPOINT = "https://api.zeptomail.com/v1.1/email";

const TOKEN_PREFIX = "Zoho-enczapikey ";

// EMAIL_FROM is a combined "Name <addr>" string (Resend's format); ZeptoMail
// needs the parts split into { address, name }.
function parseFrom(from: string): { address: string; name: string } {
  const m = from.match(/^\s*(.*?)\s*<(.+)>\s*$/);
  return m ? { name: m[1], address: m[2] } : { name: "", address: from.trim() };
}

export function createEmailSender(opts: { zeptoToken?: string; from: string; replyTo?: string }): SendEmail {
  if (!opts.zeptoToken) {
    return async () => {
      console.info("[email:dev] message accepted by development sink");
    };
  }
  const from = parseFrom(opts.from);
  // ZeptoMail's dashboard shows the token WITH the "Zoho-enczapikey " prefix, so
  // the env value commonly already includes it; only add the prefix if missing
  // (a double prefix yields a 401). We call the REST API directly rather than via
  // the `zeptomail` SDK: the SDK assumes every error body is JSON and throws an
  // opaque "Failed to parse JSON" on non-JSON error responses (e.g. a 401), which
  // masks the real status. It also pulls in node-fetch, which is fragile on Bun.
  const authorization = opts.zeptoToken.startsWith(TOKEN_PREFIX)
    ? opts.zeptoToken
    : TOKEN_PREFIX + opts.zeptoToken;
  return async ({ to, subject, text, html, clientReference }) => {
    const res = await fetch(ZEPTOMAIL_ENDPOINT, {
      method: "POST",
      signal: AbortSignal.timeout(10000),
      headers: {
        Authorization: authorization,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        from,
        track_opens: false, track_clicks: false,
        ...(opts.replyTo ? { reply_to: [{ address: opts.replyTo }] } : {}),
        to: [{ email_address: { address: to, name: to } }],
        subject,
        textbody: text,
        ...(html ? { htmlbody: html } : {}),
        // Correlates recipient events (Delivered/Bounce) back to the pending
        // sign-in in the webhook. crossDeviceStart sets this to the row id.
        ...(clientReference ? { client_reference: clientReference } : {}),
      }),
    });
    if (!res.ok) {
      const retry = res.headers.get("retry-after");
      const retryAfter = retry ? (/^\d+$/.test(retry) ? Number(retry) : Math.max(0, (Date.parse(retry) - Date.now()) / 1000)) : undefined;
      const response = await res.json().catch(() => null);
      const codes: string[] = [];
      const collect = (value: unknown, depth = 0) => {
        if (!value || typeof value !== "object" || depth > 4) return;
        for (const [key,child] of Object.entries(value)) {
          if (["code","error_code"].includes(key) && typeof child === "string" && /^[A-Z]+_\d+$/.test(child)) codes.push(child);
          else if (typeof child === "object") collect(child,depth+1);
        }
      };
      collect(response);
      const configuration = [401,403,404].includes(res.status) || codes.some((code) => ["SM_111","SM_128","SM_133","SERR_156","SERR_157","AE_101","LE_101","LE_102","SM_151"].includes(code));
      throw new EmailProviderError(configuration ? "configuration" : res.status === 429 || res.status >= 500 || codes.includes("SMI_115") ? "transient" : "permanent", Number.isFinite(retryAfter) ? retryAfter : undefined);
    }
    const body = await res.json().catch(() => null) as { request_id?: string } | null;
    return { providerId: typeof body?.request_id === "string" ? body.request_id.slice(0, 128) : undefined };
  };
}
