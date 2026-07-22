import { test, expect } from "bun:test";
import { FcmSender, type TokenSource } from "../../src/push/fcm";

const tokenSource: TokenSource = { getAccessToken: async () => "ya29.fake" };

test("send posts a data-only high-priority FCM v1 message", async () => {
  let captured: { url: string; init: RequestInit } | null = null;
  const fetchImpl = (async (url: string, init: RequestInit) => {
    captured = { url, init };
    return new Response(JSON.stringify({ name: "projects/p/messages/1" }), { status: 200 });
  }) as unknown as typeof fetch;

  const sender = new FcmSender({ projectId: "my-proj", tokenSource, fetchImpl });
  const res = await sender.send("device-token-1", { epk: "ZXBr", box: "Ym94" });

  expect(res).toBe("ok");
  expect(captured!.url).toBe("https://fcm.googleapis.com/v1/projects/my-proj/messages:send");
  const body = JSON.parse(captured!.init.body as string);
  expect(body.message.token).toBe("device-token-1");
  expect(body.message.android.priority).toBe("high");
  expect(body.message.data).toEqual({ epk: "ZXBr", box: "Ym94" });
  expect(body.message.notification).toBeUndefined(); // data-only
  expect((captured!.init.headers as Record<string,string>).authorization).toBe("Bearer ya29.fake");
});

test("send maps FCM 404 UNREGISTERED to 'unregistered'", async () => {
  const fetchImpl = (async () => {
    return new Response(JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }), { status: 404 });
  }) as unknown as typeof fetch;
  const sender = new FcmSender({ projectId: "p", tokenSource, fetchImpl });
  expect(await sender.send("dead-token", { epk: "a", box: "b" })).toBe("unregistered");
});
