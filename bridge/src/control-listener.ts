import { timingSafeEqual } from "node:crypto";
import { ControlRequestSchema, type ControlRequest, type ControlResponse } from "./control-protocol";
import { netwatch } from "./netwatch";
import { logger } from "./logger";
const log = logger.child({ component: "control-listener" });

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

/** Well inside Bun's default 10s socket idle timeout, so a quiet capture is
 *  never mistaken for a dead host by either end. */
const NETWATCH_KEEPALIVE_MS = 5_000;

/**
 * Live frame capture as server-sent events, for `antgrid watch`.
 *
 * A GET on the machine control plane rather than a `ControlRequest` verb: that
 * schema is a request/response RPC and cannot stream. It rides the same bearer
 * token because it is the same trust boundary — a loopback caller that already
 * holds host.json.
 */
function netwatchStream(url: URL): Response {
  const raw = url.searchParams.get("limit");
  const requested = Number(raw);
  // `limit=0` means "no replay, live tail only" and must not fall through to
  // the ring's default — a caller asking for nothing would otherwise be served
  // the whole 4096-event buffer and read it as live traffic.
  const limit = raw !== null && Number.isFinite(requested) && requested >= 0 ? Math.floor(requested) : undefined;
  const follow = url.searchParams.get("follow") !== "0";

  const encoder = new TextEncoder();
  let unsubscribe: (() => void) | null = null;
  let keepalive: ReturnType<typeof setInterval> | null = null;

  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const send = (line: string): void => {
        try {
          controller.enqueue(encoder.encode(line));
        } catch {
          // Reader went away mid-write; cancel() does the cleanup.
        }
      };
      // Replay before following: whatever is being chased has already happened
      // by the time someone thinks to attach a watcher.
      const replay = netwatch.snapshot(limit);
      for (const event of replay) send(`data: ${JSON.stringify(event)}\n\n`);
      send(
        `event: replayed\ndata: ${JSON.stringify({
          recorded: netwatch.recorded,
          evicted: netwatch.evicted,
          // `limit` truncates the replay independently of eviction, so these
          // two are what keep a short replay from reading as a complete one:
          // with `evicted` alone, a default `--limit 200` against a full ring
          // reports nothing missing while leaving most of the buffer unsent.
          buffered: netwatch.buffered,
          replayed: replay.length,
        })}\n\n`,
      );
      if (!follow) {
        controller.close();
        return;
      }
      unsubscribe = netwatch.subscribe((event) => send(`data: ${JSON.stringify(event)}\n\n`));
      keepalive = setInterval(() => send(": ping\n\n"), NETWATCH_KEEPALIVE_MS);
      keepalive.unref?.();
    },
    cancel() {
      unsubscribe?.();
      unsubscribe = null;
      if (keepalive) clearInterval(keepalive);
      keepalive = null;
    },
  });

  return new Response(stream, {
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-store",
      connection: "keep-alive",
    },
  });
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
        const url = new URL(req.url);
        if (req.method === "GET" && url.pathname === "/netwatch") {
          if (!bearerMatches(req.headers.get("authorization"), this.opts.token)) {
            return new Response("unauthorized", { status: 401 });
          }
          return netwatchStream(url);
        }
        if (req.method !== "POST" || url.pathname !== "/control") {
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
          log.error("control handler threw: %s", (err as Error).message);
          return json({ id: parsed.data.id, ok: false, error: { code: "INTERNAL", message: (err as Error).message } }, 500);
        }
      },
    });
    log.info(`control listener bound on 127.0.0.1:${this.server.port}`);
  }

  async stop(): Promise<void> {
    this.server?.stop(true);
    this.server = null;
  }
}
