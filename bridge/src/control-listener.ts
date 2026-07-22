import { timingSafeEqual } from "node:crypto";
import { ControlRequestSchema, type ControlRequest, type ControlResponse } from "./control-protocol";
import { logger } from "./logger";

export interface ControlListenerOptions {
  /** Bearer token a client must present (the one published in host.json). */
  token: string;
  /** Dispatches a validated request to the host; its return is the response. */
  handler: (req: ControlRequest) => Promise<ControlResponse>;
}

/** Control requests are tiny (a verb plus a couple of short strings). Cap the
 *  body so one oversized POST can't balloon the host RSS — the host is now a
 *  shared multi-project process, so a single bad client must not take down every
 *  warm core. Mirrors local-listener's payload bound. */
const MAX_CONTROL_BODY_BYTES = 64 * 1024;

function bearerMatches(header: string | null, token: string): boolean {
  if (!header || !header.startsWith("Bearer ")) return false;
  const presented = Buffer.from(header.slice("Bearer ".length));
  const expected = Buffer.from(token);
  return presented.length === expected.length && timingSafeEqual(presented, expected);
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

export class ControlListener {
  private server: ReturnType<typeof Bun.serve> | null = null;
  constructor(private readonly opts: ControlListenerOptions) {}

  get port(): number {
    if (!this.server?.port) throw new Error("control listener not started");
    return this.server.port;
  }

  async start(): Promise<void> {
    this.server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      maxRequestBodySize: MAX_CONTROL_BODY_BYTES,
      fetch: async (req) => {
        if (req.method !== "POST" || new URL(req.url).pathname !== "/control") {
          return new Response("not found", { status: 404 });
        }
        if (!bearerMatches(req.headers.get("authorization"), this.opts.token)) {
          return new Response("unauthorized", { status: 401 });
        }
        let raw: unknown;
        // id is unknown here (the body didn't parse), so use "" — same
        // convention as the BAD_REQUEST path — to satisfy the ControlResponse
        // contract that every response carries an id.
        try { raw = await req.json(); } catch { return json({ id: "", ok: false, error: { code: "BAD_JSON", message: "invalid JSON body" } }, 400); }
        const parsed = ControlRequestSchema.safeParse(raw);
        if (!parsed.success) {
          const id = typeof (raw as any)?.id === "string" ? (raw as any).id : "";
          return json({ id, ok: false, error: { code: "BAD_REQUEST", message: parsed.error.issues.map((i) => i.message).join("; ") } }, 400);
        }
        try {
          const res = await this.opts.handler(parsed.data);
          return json(res, res.ok ? 200 : 400);
        } catch (err) {
          logger.error("control handler threw: %s", (err as Error).message);
          return json({ id: parsed.data.id, ok: false, error: { code: "INTERNAL", message: (err as Error).message } }, 500);
        }
      },
    });
    logger.info(`control listener bound on 127.0.0.1:${this.server.port}`);
  }

  async stop(): Promise<void> {
    this.server?.stop(true);
    this.server = null;
  }
}
