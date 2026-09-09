// The browser half of the capture viewer: the credentials it runs on, and the
// four routes it reaches. What is pinned here is mostly what the viewer may NOT
// do — a ticket may not be spent twice, a session may not name a control verb,
// and a page reaching this port under any name but the one it was published at
// gets nothing.
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { connect } from "node:net";
import { ControlListener } from "../src/control-listener";
import { netwatchUiPage } from "../src/netwatch-ui-page";
import type { ControlRequest, ControlResponse } from "../src/control-protocol";
import {
  TICKET_TTL_MS,
  mintUiTicket,
  redeemUiTicket,
  resetNetwatchUiCredentials,
  validateUiSession,
} from "../src/netwatch-ui-session";

const HOST_TOKEN = "host-bearer-token";

describe("viewer credentials", () => {
  beforeEach(() => resetNetwatchUiCredentials());

  it("spends a ticket exactly once", () => {
    const ticket = mintUiTicket();
    const session = redeemUiTicket(ticket);
    expect(typeof session).toBe("string");
    // The URL that carried it still exists — in history, in a paste. This is
    // what makes that copy worthless.
    expect(redeemUiTicket(ticket)).toBeNull();
  });

  it("refuses a ticket older than its window, and burns it anyway", () => {
    const t0 = 1_000_000;
    const ticket = mintUiTicket(t0);
    expect(redeemUiTicket(ticket, t0 + TICKET_TTL_MS + 1)).toBeNull();
    expect(redeemUiTicket(ticket, t0 + 1)).toBeNull();
  });

  it("slides a session's window on every use", () => {
    const t0 = 5_000_000;
    const session = redeemUiTicket(mintUiTicket(t0), t0)!;
    const day = 24 * 60 * 60 * 1000;
    // Idle past the window would lapse; used inside it, then used again a long
    // way past where the ORIGINAL window ended, it is still live.
    expect(validateUiSession(session, t0 + 4 * 60 * 60 * 1000)).toBe(true);
    expect(validateUiSession(session, t0 + 11 * 60 * 60 * 1000)).toBe(true);
    expect(validateUiSession(session, t0 + day)).toBe(false);
  });

  it("refuses a token it never minted", () => {
    redeemUiTicket(mintUiTicket());
    expect(validateUiSession("f".repeat(64))).toBe(false);
  });
});

describe("the viewer document", () => {
  const NONCE = "deadbeefdeadbeef";

  function script(): string {
    const { html } = netwatchUiPage(NONCE);
    const open = `<script nonce="${NONCE}">`;
    const from = html.indexOf(open);
    expect(from).toBeGreaterThan(-1);
    const to = html.indexOf("</" + "script>", from);
    return html.slice(from + open.length, to);
  }

  it("ships a script that parses", () => {
    // The page is a string in a TypeScript file, so nothing between here and a
    // browser ever compiles it. A syntax error would render as an empty shell
    // with the reason only in the viewer's own console.
    expect(() => new Function(script())).not.toThrow();
  });

  it("puts nothing on the page as markup", () => {
    // Every value the viewer renders was written by a peer — a message type off
    // the relay, a body off an agent's stdout. textContent is the whole defence
    // and this is what keeps a later edit from reaching for the easy thing.
    const body = script();
    for (const escape of ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"]) {
      expect(body).not.toContain(escape);
    }
  });
});

describe("viewer routes", () => {
  let listener: ControlListener | null = null;
  let seen: ControlRequest[] = [];

  beforeEach(() => {
    resetNetwatchUiCredentials();
    seen = [];
  });
  afterEach(async () => {
    await listener?.stop();
    listener = null;
  });

  async function start(): Promise<number> {
    listener = new ControlListener({
      token: HOST_TOKEN,
      handler: async (req: ControlRequest): Promise<ControlResponse> => {
        seen.push(req);
        if (req.type === "netwatch:local") {
          return { id: req.id, ok: true, type: "netwatch:local", bodies: req.bodies, ttlMs: 60_000 };
        }
        return { id: req.id, ok: true, type: "project:list", projects: [] };
      },
    });
    await listener.start();
    return listener.port;
  }

  /** A session token, obtained the way the page obtains one. */
  async function session(port: number): Promise<string> {
    const res = await fetch(`http://127.0.0.1:${port}/netwatch/ui/session`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ticket: mintUiTicket() }),
    });
    expect(res.status).toBe(200);
    return ((await res.json()) as { token: string }).token;
  }

  it("serves the viewer with a nonce bound into the policy and both inline blocks", async () => {
    const port = await start();
    const res = await fetch(`http://127.0.0.1:${port}/netwatch/ui`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");

    const csp = res.headers.get("content-security-policy") ?? "";
    const nonce = /script-src 'nonce-([0-9a-f]+)'/.exec(csp)?.[1];
    expect(nonce).toBeTruthy();
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("frame-ancestors 'none'");

    const html = await res.text();
    expect(html).toContain(`<script nonce="${nonce}">`);
    expect(html).toContain(`<style nonce="${nonce}">`);
    // A placeholder that survived would leave the page's own script unrunnable
    // under its own policy, and the failure is silent in a browser.
    expect(html).not.toContain("__NONCE__");
  });

  it("mints a distinct nonce per response", async () => {
    const port = await start();
    const one = await (await fetch(`http://127.0.0.1:${port}/netwatch/ui`)).headers.get("content-security-policy");
    const two = await (await fetch(`http://127.0.0.1:${port}/netwatch/ui`)).headers.get("content-security-policy");
    expect(one).not.toBe(two);
  });

  it("does not answer a name that merely resolves to this address", async () => {
    // The shape of DNS rebinding: the socket lands here, but the document
    // believes its origin is somewhere the attacker controls.
    const port = await start();
    const reply = await rawGet(port, "/netwatch/ui", "netwatch.example.com");
    expect(reply.split(" ")[1]).toBe("404");
  });

  it("still answers the address it was published at", async () => {
    const port = await start();
    const reply = await rawGet(port, "/netwatch/ui", `127.0.0.1:${port}`);
    expect(reply.split(" ")[1]).toBe("200");
  });

  it("refuses a cross-site fetch even with a valid session", async () => {
    const port = await start();
    const token = await session(port);
    const res = await fetch(`http://127.0.0.1:${port}/netwatch?follow=0`, {
      headers: { authorization: `Bearer ${token}`, "sec-fetch-site": "cross-site" },
    });
    expect(res.status).toBe(404);
  });

  it("refuses a session request carrying a spent ticket", async () => {
    const port = await start();
    const ticket = mintUiTicket();
    const body = JSON.stringify({ ticket });
    const opts = { method: "POST", headers: { "content-type": "application/json" }, body };
    expect((await fetch(`http://127.0.0.1:${port}/netwatch/ui/session`, opts)).status).toBe(200);
    expect((await fetch(`http://127.0.0.1:${port}/netwatch/ui/session`, opts)).status).toBe(401);
  });

  it("reads the capture stream on a session token", async () => {
    const port = await start();
    const token = await session(port);
    const res = await fetch(`http://127.0.0.1:${port}/netwatch?follow=0`, {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    expect(await res.text()).toContain("event: replayed");
  });

  it("refuses the stream to a token nobody minted", async () => {
    const port = await start();
    const res = await fetch(`http://127.0.0.1:${port}/netwatch?follow=0`, {
      headers: { authorization: `Bearer ${"a".repeat(64)}` },
    });
    expect(res.status).toBe(401);
  });

  it("arms body capture through the one plane the viewer has", async () => {
    const port = await start();
    const token = await session(port);
    const res = await fetch(`http://127.0.0.1:${port}/netwatch/ui/arm`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ id: "ui-arm", type: "netwatch:local", bodies: true, ttlMs: 300_000 }),
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true, type: "netwatch:local", bodies: true });
    expect(seen.map((r) => r.type)).toEqual(["netwatch:local"]);
  });

  it("cannot reach a control verb outside the arming pair", async () => {
    const port = await start();
    const token = await session(port);
    const res = await fetch(`http://127.0.0.1:${port}/netwatch/ui/arm`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ id: "x", type: "project:stop", projectId: "p1" }),
    });
    expect(res.status).toBe(403);
    // The refusal is at the door, not at the handler: nothing downstream had to
    // know a viewer exists.
    expect(seen).toEqual([]);
  });

  it("refuses an arm with no credential at all", async () => {
    const port = await start();
    const res = await fetch(`http://127.0.0.1:${port}/netwatch/ui/arm`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id: "x", type: "netwatch:local", bodies: false }),
    });
    expect(res.status).toBe(401);
    expect(seen).toEqual([]);
  });

  it("leaves the host bearer working on every viewer route it should", async () => {
    const port = await start();
    const res = await fetch(`http://127.0.0.1:${port}/netwatch?follow=0`, {
      headers: { authorization: `Bearer ${HOST_TOKEN}` },
    });
    expect(res.status).toBe(200);
  });
});

/** A request with a Host header of our choosing. `fetch` derives Host from the
 *  URL and will not be told otherwise, and Host is the field the rebinding
 *  guard reads. */
function rawGet(port: number, path: string, host: string): Promise<string> {
  const CRLF = String.fromCharCode(13, 10);
  return new Promise((resolve, reject) => {
    const sock = connect(port, "127.0.0.1", () => {
      sock.write(`GET ${path} HTTP/1.1${CRLF}Host: ${host}${CRLF}Connection: close${CRLF}${CRLF}`);
    });
    let out = "";
    sock.setTimeout(5_000, () => sock.destroy(new Error("timed out")));
    sock.on("data", (chunk) => { out += chunk.toString(); });
    sock.on("end", () => resolve(out));
    sock.on("error", reject);
  });
}
