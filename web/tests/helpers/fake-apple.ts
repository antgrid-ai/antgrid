// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

/** An Apple id token as the token endpoint returns it. Unsigned: the code under
 *  test decodes these without verifying (they arrive over TLS from Apple). */
export function appleIdToken(claims: { sub: string; aud: string }): string {
  const part = (v: object) => Buffer.from(JSON.stringify(v)).toString("base64url");
  return `${part({ alg: "ES256", kid: "k" })}.${part({ iss: "https://appleid.apple.com", ...claims })}.sig`;
}

export type AppleCall = { url: string; form: URLSearchParams };

/** Records every request to Apple and answers from `respond`. */
export function fakeAppleFetch(respond: (call: AppleCall) => Response) {
  const calls: AppleCall[] = [];
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const call = { url: String(input), form: new URLSearchParams(String(init?.body ?? "")) };
    calls.push(call);
    return respond(call);
  }) as typeof fetch;
  return { calls, fetchImpl };
}
