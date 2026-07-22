import { afterEach, describe, expect, test } from "bun:test";
import { createEmailSender } from "../../src/auth/email.js";

const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; });

describe("createEmailSender client_reference", () => {
  test("includes client_reference in the ZeptoMail body when provided", async () => {
    let sentBody: any = null;
    globalThis.fetch = (async (_url: any, init: any) => {
      sentBody = JSON.parse(init.body);
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    const send = createEmailSender({ zeptoToken: "test-token", from: "Antgrid <no-reply@x.test>" });
    await send({ to: "a@example.com", subject: "s", text: "t", clientReference: "row-123" });

    expect(sentBody.client_reference).toBe("row-123");
  });

  test("omits client_reference when not provided", async () => {
    let sentBody: any = null;
    globalThis.fetch = (async (_url: any, init: any) => {
      sentBody = JSON.parse(init.body);
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    const send = createEmailSender({ zeptoToken: "test-token", from: "Antgrid <no-reply@x.test>" });
    await send({ to: "a@example.com", subject: "s", text: "t" });

    expect("client_reference" in sentBody).toBe(false);
  });
});
