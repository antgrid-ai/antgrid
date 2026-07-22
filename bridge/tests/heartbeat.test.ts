import { describe, it, expect } from "bun:test";
import { sendHeartbeat } from "../src/heartbeat";

describe("sendHeartbeat", () => {
  it("POSTs the correct URL, headers, and body", async () => {
    let capturedUrl = "";
    let capturedInit: RequestInit | undefined;

    const fakeFetch = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      capturedUrl = input as string;
      capturedInit = init;
      return new Response(null, { status: 200 });
    }) as typeof fetch;

    await sendHeartbeat({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "test-token",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      mobileAccessEnabled: true,
      relayUrl: "wss://relay.example.com",
      fetchFn: fakeFetch,
    });

    expect(capturedUrl).toBe(
      "https://api.example.com/account/devices/me/heartbeat",
    );
    expect((capturedInit?.headers as Record<string, string>)["authorization"]).toBe(
      "Bearer test-token",
    );
    expect((capturedInit?.headers as Record<string, string>)["content-type"]).toBe(
      "application/json",
    );
    expect(capturedInit?.method).toBe("POST");

    const body = JSON.parse(capturedInit?.body as string);
    expect(body.deviceUuid).toBe("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    expect(body.mobileAccessEnabled).toBe(true);
    expect(body.relayUrl).toBe("wss://relay.example.com");
  });

  it("returns false on non-2xx response; returns true on 2xx", async () => {
    const makeResponse = (status: number): typeof fetch =>
      (async (_input: Parameters<typeof fetch>[0], _init?: Parameters<typeof fetch>[1]) =>
        new Response(null, { status })) as typeof fetch;

    const ok = await sendHeartbeat({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "tok",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      mobileAccessEnabled: true,
      fetchFn: makeResponse(200),
    });
    expect(ok).toBe(true);

    const notFound = await sendHeartbeat({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "tok",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      mobileAccessEnabled: true,
      fetchFn: makeResponse(404),
    });
    expect(notFound).toBe(false);

    const serverError = await sendHeartbeat({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "tok",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      mobileAccessEnabled: true,
      fetchFn: makeResponse(500),
    });
    expect(serverError).toBe(false);
  });

  it("returns false on network error (fetch throws)", async () => {
    const throwingFetch = (async (_input: Parameters<typeof fetch>[0], _init?: Parameters<typeof fetch>[1]): Promise<Response> => {
      throw new Error("network failure");
    }) as typeof fetch;

    const result = await sendHeartbeat({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "tok",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      mobileAccessEnabled: true,
      fetchFn: throwingFetch,
    });
    expect(result).toBe(false);
  });

  it("includes machineName in the body", async () => {
    let capturedBody = "";

    const fakeFetch = (async (_input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      capturedBody = init?.body as string;
      return new Response(null, { status: 200 });
    }) as typeof fetch;

    await sendHeartbeat({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "tok",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      mobileAccessEnabled: true,
      relayUrl: "wss://relay.example.com",
      machineName: "Mac Studio",
      fetchFn: fakeFetch,
    });

    const body = JSON.parse(capturedBody);
    expect(body.machineName).toBe("Mac Studio");
  });

  it("sends null machineName when not provided", async () => {
    let capturedBody = "";

    const fakeFetch = (async (_input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      capturedBody = init?.body as string;
      return new Response(null, { status: 200 });
    }) as typeof fetch;

    await sendHeartbeat({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "tok",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      mobileAccessEnabled: false,
      fetchFn: fakeFetch,
    });

    const body = JSON.parse(capturedBody);
    expect(body.machineName).toBeNull();
  });

  it("sends null relayUrl when not provided", async () => {
    let capturedBody = "";

    const fakeFetch = (async (_input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      capturedBody = init?.body as string;
      return new Response(null, { status: 200 });
    }) as typeof fetch;

    await sendHeartbeat({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "tok",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      mobileAccessEnabled: false,
      fetchFn: fakeFetch,
    });

    const body = JSON.parse(capturedBody);
    expect(body.relayUrl).toBeNull();
    expect(body.mobileAccessEnabled).toBe(false);
  });
});
