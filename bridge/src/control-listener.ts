import { randomBytes, timingSafeEqual } from "node:crypto";
import { ControlRequestSchema, type ControlRequest, type ControlResponse } from "./control-protocol";
import { netwatch } from "./netwatch";
import { isContextCaptureArmed, modelwatch } from "./modelwatch";
import { netwatchUiPage } from "./netwatch-ui-page";
import { redeemUiTicket, validateUiSession } from "./netwatch-ui-session";
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

function bearerToken(header: string | null): string | null {
  if (!header || !header.startsWith("Bearer ")) return null;
  return header.slice("Bearer ".length);
}

function bearerMatches(header: string | null, token: string): boolean {
  const presented = bearerToken(header);
  if (presented === null) return false;
  const a = Buffer.from(presented);
  const b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * Whether a browser could have been tricked into making this request.
 *
 * Everything below `/netwatch`, and the `/modelwatch` feed beside it, is
 * reachable from a page, which brings two attacks the bearer alone does not
 * answer. DNS rebinding gives an attacker's document a `Host` of its own domain
 * while the socket lands here, so a `Host` this listener never published means
 * the request came by a name rather than by the address — refuse it.
 * `Sec-Fetch-Site` and `Origin` are set by the browser and cannot be forged by
 * page script, so their ABSENCE is what identifies a non-browser caller (the
 * CLI, curl) and anything cross-site is refused.
 *
 * `/control` is deliberately left alone: it is not reachable from the viewer,
 * its clients predate these headers, and widening a guard onto the plane that
 * starts projects is not something a diagnostics feature gets to do.
 */
function browserGuardsPass(req: Request, port: number): boolean {
  const host = req.headers.get("host");
  if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}` && host !== `[::1]:${port}`) {
    return false;
  }
  const site = req.headers.get("sec-fetch-site");
  if (site !== null && site !== "same-origin" && site !== "none") return false;
  const origin = req.headers.get("origin");
  if (origin !== null && origin !== `http://127.0.0.1:${port}` && origin !== `http://localhost:${port}`) {
    return false;
  }
  return true;
}

/** The verbs a viewer session may reach. It holds a credential derived from the
 *  host bearer, not the bearer itself, so the narrowing has to be stated here
 *  rather than inherited: everything else on `ControlRequestSchema` starts
 *  projects, checks out branches or discloses host paths. */
const UI_ARMABLE = new Set(["netwatch:local", "netwatch:remote", "modelwatch:arm"]);

/**
 * Why an arming request is not reachable from the viewer, or `null` if it is.
 *
 * The set above is the coarse half. The fine half is that `modelwatch:arm` is
 * admitted for its PROMPT arm and refused for its CONTEXT arm, which is not
 * symmetry with netwatch and not an oversight. Netwatch's armable bodies are
 * relay frames: typed, bounded by the frame size, and covered by
 * `BODY_REDACTED_MESSAGE_TYPES` for the ones that carry credentials. The context
 * arm admits the transcript and PTY scrollback a decision prompt is built
 * around — thousands of characters with no type, and no list that could ever be
 * written to make them safe, which is exactly why modelwatch.ts gives it a
 * second switch instead of folding it into the first. A pasted key, an `.env`
 * the agent opened, a password typed at a prompt all reach the ring through it.
 *
 * A viewer session is minted through the ticket exchange by someone already
 * holding the host bearer, so this is defence in depth rather than a trust
 * boundary. What it costs that operator is one CLI flag on the plane where the
 * same verb is answered in full. What it buys is that a page which got at a
 * session — a ticket still sitting in a URL someone pasted, a tab left open, an
 * extension reading the address bar — cannot turn a diagnostics viewer into a
 * transcript exfiltrator with a single POST.
 *
 * Decided by the ROUTE rather than by which of the two credentials opened it:
 * the host bearer reaches this route only from a test or a curl and already has
 * `/control`, so keying the refusal on precedence between the two branches of
 * one `authed` boolean would add a way to get it wrong in exchange for nothing.
 *
 * DISARMING the context arm stays reachable — the hazard is admitting text, and
 * a viewer that can only ever turn the thing off is not one.
 *
 * Which is why the refusal is keyed on the GATE a request moves rather than on
 * the arm it names. Transcript text and the model's answer are admitted iff both
 * arms are up (`sessionTextArmed` in modelwatch.ts), so with the context arm
 * already standing alone — a state the host answers `{prompts:false,
 * context:true}` and records nothing under — arming `prompts` is what starts
 * admitting the transcript. Refusing only the request that says the word
 * "context" would let a viewer reach that through the half of the pair that
 * looks harmless, which is the single POST this narrowing exists to prevent. The
 * CLI never lands in that state (it always arms the pair together), so what the
 * added clause costs a legitimate viewer is nothing.
 *
 * The refusal carries its own code so a viewer can say WHY. Under the set's
 * `FORBIDDEN` the verb would read as one the viewer has no access to at all,
 * which is the opposite of true and leaves the operator with nothing to act on.
 */
function uiArmRefusal(req: ControlRequest): { code: string; message: string } | null {
  if (!UI_ARMABLE.has(req.type)) {
    return { code: "FORBIDDEN", message: "not reachable from the capture viewer" };
  }
  if (req.type === "modelwatch:arm" && req.enabled && (req.arms.includes("context") || isContextCaptureArmed())) {
    return {
      code: "CONTEXT_ARM_FORBIDDEN",
      message: "the context arm records transcript text and is reachable only from the CLI",
    };
  }
  return null;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

/** Well inside Bun's default 10s socket idle timeout, so a quiet capture is
 *  never mistaken for a dead host by either end. */
const CAPTURE_KEEPALIVE_MS = 5_000;

/** All a capture stream needs of a ring. Netwatch's frames and modelwatch's
 *  model calls answer the same four questions and differ only in what they
 *  hold, so the endpoint below is written once against this rather than twice
 *  against two rings that would then drift apart on shedding or replay meta. */
interface CaptureRing<E> {
  snapshot(limit?: number): E[];
  subscribe(fn: (event: E) => void): () => void;
  readonly recorded: number;
  readonly evicted: number;
  readonly buffered: number;
}

/**
 * A live capture as server-sent events — relay and loopback frames for
 * `antgrid watch`, headless model calls for its sibling.
 *
 * A GET on the machine control plane rather than a `ControlRequest` verb: that
 * schema is a request/response RPC and cannot stream. It rides the same bearer
 * token because it is the same trust boundary — a loopback caller that already
 * holds host.json.
 */
function captureStream<E>(ring: CaptureRing<E>, url: URL): Response {
  const raw = url.searchParams.get("limit");
  const requested = Number(raw);
  // `limit=0` means "no replay, live tail only" and must not fall through to
  // the ring's default — a caller asking for nothing would otherwise be served
  // the ring's whole buffer (each ring's own `DEFAULT_CAPACITY`, larger still
  // under its own capacity env var) and read it as live traffic.
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
      const replay = ring.snapshot(limit);
      for (const event of replay) send(`data: ${JSON.stringify(event)}\n\n`);
      send(
        `event: replayed\ndata: ${JSON.stringify({
          recorded: ring.recorded,
          evicted: ring.evicted,
          // `limit` truncates the replay independently of eviction, so these
          // two are what keep a short replay from reading as a complete one:
          // with `evicted` alone, a default `--limit 200` against a full ring
          // reports nothing missing while leaving most of the buffer unsent.
          buffered: ring.buffered,
          replayed: replay.length,
        })}\n\n`,
      );
      if (!follow) {
        controller.close();
        return;
      }
      // Shed rather than queue when the reader falls behind. `enqueue` neither
      // blocks nor throws past the high-water mark, so an unchecked live send
      // grows this stream's internal queue without bound — and the producer is
      // every loopback frame of every project, which on a scrolling build
      // outruns a TTY render or a synchronous `--export` append with room to
      // spare. The bridge owns every project core and PTY in this process, so
      // an observer that can OOM it kills the thing it was attached to watch.
      // The count is reported on the next send that fits, because a silent gap
      // is exactly the blind spot the replay meta already exists to name.
      let shed = 0;
      unsubscribe = ring.subscribe((event) => {
        const room = controller.desiredSize;
        if (room !== null && room <= 0) {
          shed++;
          return;
        }
        if (shed > 0) {
          send(`event: shed\ndata: ${JSON.stringify({ dropped: shed })}\n\n`);
          shed = 0;
        }
        send(`data: ${JSON.stringify(event)}\n\n`);
      });
      keepalive = setInterval(() => send(": ping\n\n"), CAPTURE_KEEPALIVE_MS);
      keepalive.unref?.();
    },
    cancel() {
      unsubscribe?.();
      unsubscribe = null;
      if (keepalive) clearInterval(keepalive);
      keepalive = null;
    },
  // The default strategy counts ONE chunk, so `desiredSize` goes non-positive
  // the moment a single event is queued unread — which is every burst, reader
  // keeping up or not, and would shed almost everything. This is the buffer the
  // shedding defends: deep enough that a normal reader never loses a row,
  // bounded so a stalled one costs a known amount of memory rather than the
  // process.
  }, new CountQueuingStrategy({ highWaterMark: 1024 }));

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

  /** Either credential opens a capture stream: the CLI presents the host bearer
   *  out of host.json, the viewer a session derived from a ticket that same
   *  bearer minted. Named once because three routes across two features have to
   *  agree on it. */
  private authed(req: Request): boolean {
    const header = req.headers.get("authorization");
    const presented = bearerToken(header);
    return bearerMatches(header, this.opts.token) ||
      (presented !== null && validateUiSession(presented));
  }

  /**
   * `GET /modelwatch`: the headless model-call feed.
   *
   * The same trust boundary and the same two credentials as `/netwatch`. It has
   * no `/ui` and no `/arm` of its own — the viewer is meant to be one document
   * reading both feeds (the model-call tab itself is not written yet), so arming
   * rides the POST that page already has, under the narrowing in `uiArmRefusal`.
   */
  private handleModelwatch(req: Request, url: URL): Response {
    if (req.method !== "GET" || url.pathname !== "/modelwatch") {
      return new Response("not found", { status: 404 });
    }
    if (!this.authed(req)) return new Response("unauthorized", { status: 401 });
    return captureStream(modelwatch, url);
  }

  /**
   * Everything under `/netwatch`: the stream the CLI and the viewer both read,
   * the viewer document itself, and the two POSTs that turn a launch ticket
   * into a client of that stream. All of it has already passed
   * `browserGuardsPass`.
   */
  private async handleNetwatch(req: Request, url: URL): Promise<Response> {
    const authed = this.authed(req);

    if (req.method === "GET" && url.pathname === "/netwatch") {
      if (!authed) return new Response("unauthorized", { status: 401 });
      return captureStream(netwatch, url);
    }

    if (req.method === "GET" && url.pathname === "/netwatch/ui") {
      // Unauthenticated on purpose: a browser sends no bearer on a navigation,
      // and this document holds no capture and no credential. It is inert until
      // it can spend a ticket for one.
      const { html, csp } = netwatchUiPage(randomBytes(16).toString("hex"));
      return new Response(html, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "content-security-policy": csp,
          "cache-control": "no-store",
          "referrer-policy": "no-referrer",
          "x-content-type-options": "nosniff",
        },
      });
    }

    if (req.method === "POST" && url.pathname === "/netwatch/ui/session") {
      let raw: unknown;
      try { raw = await req.json(); } catch { return new Response("bad json", { status: 400 }); }
      const ticket = (raw as { ticket?: unknown } | null)?.ticket;
      const session = typeof ticket === "string" ? redeemUiTicket(ticket) : null;
      // Unknown, spent and lapsed are one answer: telling them apart tells a
      // guesser which half of the guess was right.
      if (session === null) return new Response("unauthorized", { status: 401 });
      return json({ token: session });
    }

    if (req.method === "POST" && url.pathname === "/netwatch/ui/arm") {
      if (!authed) return new Response("unauthorized", { status: 401 });
      let raw: unknown;
      try {
        raw = await req.json();
      } catch {
        return json({ id: "", ok: false, error: { code: "BAD_JSON", message: "invalid JSON body" } }, 400);
      }
      const parsed = ControlRequestSchema.safeParse(raw);
      if (!parsed.success) {
        const id = typeof (raw as any)?.id === "string" ? (raw as any).id : "";
        return json({ id, ok: false, error: { code: "BAD_REQUEST", message: parsed.error.issues.map((i) => i.message).join("; ") } }, 400);
      }
      // The schema admits every control verb; this route admits three, and one
      // of those only for part of what it can ask for.
      const refusal = uiArmRefusal(parsed.data);
      if (refusal) {
        return json({ id: parsed.data.id, ok: false, error: refusal }, 403);
      }
      try {
        const res = await this.opts.handler(parsed.data);
        return json(res, res.ok ? 200 : 400);
      } catch (err) {
        log.error("netwatch arm threw: %s", (err as Error).message);
        return json({ id: parsed.data.id, ok: false, error: { code: "INTERNAL", message: (err as Error).message } }, 500);
      }
    }

    return new Response("not found", { status: 404 });
  }

  async start(): Promise<void> {
    this.server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      maxRequestBodySize: MAX_CONTROL_BODY_BYTES,
      fetch: async (req, server) => {
        const url = new URL(req.url);
        // Undefined only for a unix-socket server, which this never is; the
        // guard would have nothing to compare a Host against, so refuse rather
        // than wave the request through.
        const port = server.port;
        // `/modelwatch` takes the same treatment as everything under
        // `/netwatch`: a page that can reach one can reach the other, so the
        // rebinding and cross-site guards are what stand between a document on
        // an attacker's domain and this machine's capture — before either route
        // gets as far as looking at a credential.
        if (
          url.pathname === "/netwatch" ||
          url.pathname.startsWith("/netwatch/") ||
          url.pathname === "/modelwatch"
        ) {
          if (port === undefined || !browserGuardsPass(req, port)) {
            return new Response("not found", { status: 404 });
          }
          return url.pathname === "/modelwatch"
            ? this.handleModelwatch(req, url)
            : this.handleNetwatch(req, url);
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
