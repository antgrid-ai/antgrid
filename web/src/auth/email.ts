export type SendEmail = (args: {
  to: string;
  subject: string;
  text: string;
  html?: string;
  clientReference?: string;
}) => Promise<void>;

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

export function createEmailSender(opts: { zeptoToken?: string; from: string }): SendEmail {
  if (!opts.zeptoToken) {
    return async ({ to, subject, text }) => {
      console.log(`[email:dev] to=${to} subject=${subject}\n${text}`);
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
      headers: {
        Authorization: authorization,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        from,
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
      const body = await res.text().catch(() => "");
      throw new Error(`ZeptoMail send failed (${res.status} ${res.statusText}): ${body.slice(0, 500)}`);
    }
  };
}
