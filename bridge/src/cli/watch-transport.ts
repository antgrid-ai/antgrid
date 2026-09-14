// The half of a watcher CLI that is not about what it is watching: reaching the
// loopback control plane, reading an SSE capture stream off it, what that
// stream's two control frames MEAN, holding an armed capture open for exactly as
// long as this process lives, and handing a minted viewer link to a browser.
// Netwatch and Modelwatch share all of it and share none of the rendering that
// is about their own subject — what a frame is against what a model call is, and
// how either one reads — which is the line this file is drawn on. The colours and
// the clock sit on this side of it because they are about a terminal rather than
// about either subject, and two copies of an escape table drift in silence.
import { openStandaloneWindow } from "./open-window";

/** The loopback control plane as a CLI addresses it — the port the host bound
 *  and the bearer it wrote into host.json. Both come from `readHostFile` and
 *  from nowhere else: the plane is bound to 127.0.0.1 and that token is the
 *  whole of its authentication. */
export interface ControlHost {
  controlPort: number;
  token: string;
}

/**
 * Dead-man switch on an armed capture, and the heartbeat that holds it open.
 *
 * Every armed endpoint disarms itself when the window lapses — the app for a
 * remote capture, this host for whatever payloads it was asked to record — so a
 * watcher killed with SIGKILL, or a laptop that closes mid-session, cannot leave
 * anything recording indefinitely. The heartbeat is well inside the window so a
 * single dropped re-arm costs nothing.
 */
export const CAPTURE_TTL_MS = 300_000;

/** The renewal cadence a window of `ttlMs` demands. The window an arm actually
 *  gets is the host's to decide (it clamps), so the cadence is derived from the
 *  answer rather than fixed — a capture shortened behind the watcher's back
 *  would otherwise lapse under re-arms that believed they were early. */
export function heartbeatFor(ttlMs: number): number {
  return Math.max(1_000, Math.floor(ttlMs * 0.4));
}

/** One control verb at the loopback plane. `error` is null on success — the
 *  caller decides whether a failure is fatal (arming) or worth only a note (the
 *  disarm on the way out). `idPrefix` names the calling subcommand in the
 *  correlation id the host echoes back, and is the only part of a request that
 *  is not shared between watchers. */
export async function postControl(
  host: ControlHost,
  verb: Record<string, unknown>,
  idPrefix: string,
): Promise<{ error: string | null; reply?: Record<string, unknown> }> {
  let res: Response;
  try {
    res = await fetch(`http://127.0.0.1:${host.controlPort}/control`, {
      method: "POST",
      headers: { authorization: `Bearer ${host.token}`, "content-type": "application/json" },
      body: JSON.stringify({ id: `${idPrefix}-${Date.now()}`, ...verb }),
    });
  } catch (err) {
    return { error: (err as Error).message };
  }
  if (!res.ok) return { error: `HTTP ${res.status}` };
  let body: { ok: boolean; error?: { message?: string } } & Record<string, unknown>;
  try {
    body = (await res.json()) as typeof body;
  } catch {
    // A 200 whose body is not JSON — a host shutting down mid-response. The
    // disarm on the way out calls this from a SIGINT handler, so a throw here
    // would take the exit with it.
    return { error: "malformed reply" };
  }
  return body.ok ? { error: null, reply: body } : { error: body.error?.message ?? "refused" };
}

export function parseJson<T>(raw: string): T | null {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

/** Parses an SSE byte stream into whole events. */
export async function* sseEvents(body: ReadableStream<Uint8Array>): AsyncGenerator<{ event?: string; data: string }> {
  const decoder = new TextDecoder();
  const reader = body.getReader();
  let buffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) return;
    buffer += decoder.decode(value, { stream: true });
    let split: number;
    while ((split = buffer.indexOf("\n\n")) !== -1) {
      const block = buffer.slice(0, split);
      buffer = buffer.slice(split + 2);
      if (block.startsWith(":")) continue; // keepalive
      let name: string | undefined;
      const data: string[] = [];
      for (const line of block.split("\n")) {
        if (line.startsWith("event:")) name = line.slice(6).trim();
        else if (line.startsWith("data:")) data.push(line.slice(5).trim());
      }
      if (data.length > 0) yield { event: name, data: data.join("\n") };
    }
  }
}

/**
 * What the stream's `replayed` frame says it could NOT give this reader, in the
 * watcher's own noun ("events", "records").
 *
 * The frame is emitted once, by one endpoint, for both watchers — so its meaning
 * is decoded once too. Two copies of these field names would compile, pass and
 * silently disagree the first time the endpoint gained a field or renamed one:
 * whichever CLI was not the obvious consumer would go on reporting the old note,
 * with nothing to catch it.
 *
 * The two gaps are separate because their remedies are. An eviction is history
 * the ring no longer holds and nothing recovers it; a short replay is history it
 * still holds and `--limit` asks for more of it.
 */
export function replayGaps(data: string, noun: string): string[] {
  const meta = parseJson<{ evicted?: number; buffered?: number; replayed?: number }>(data);
  if (!meta) return [];
  const notes: string[] = [];
  if ((meta.evicted ?? 0) > 0) notes.push(`${meta.evicted} older ${noun} already evicted`);
  if ((meta.replayed ?? 0) < (meta.buffered ?? 0)) {
    notes.push(`${(meta.buffered ?? 0) - (meta.replayed ?? 0)} buffered ${noun} not replayed — raise --limit`);
  }
  return notes;
}

/** How many live records the host dropped because THIS reader could not keep up
 *  — a gap in what reached the screen, not in what the machine did. Decoded here
 *  for `replayGaps`'s reason. */
export function shedCount(data: string): number {
  return parseJson<{ dropped?: number }>(data)?.dropped ?? 0;
}

export const COLOR = {
  dim: "\u001b[2m",
  red: "\u001b[31m",
  yellow: "\u001b[33m",
  cyan: "\u001b[36m",
  green: "\u001b[32m",
  reset: "\u001b[0m",
};

export function paint(text: string, color: keyof typeof COLOR, enabled: boolean): string {
  return enabled ? `${COLOR[color]}${text}${COLOR.reset}` : text;
}

export function clock(at: number): string {
  const d = new Date(at);
  const p = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

/** One capture a run can hold open on the host. */
export interface CaptureArm {
  /** How a failed disarm names it to the operator — "the app's capture". */
  what: string;
  /** Arm or disarm, reporting the window the host ACTUALLY granted. The grant
   *  rather than the request, because the host clamps and a heartbeat pacing
   *  itself off what it asked for would let the dead man's switch lapse
   *  mid-run. */
  set(enabled: boolean): Promise<{ error: string | null; ttlMs: number }>;
}

/**
 * The captures a run has armed, and the heartbeat holding them open.
 *
 * What is actually armed, not what was asked for: a run that arms one capture
 * and then fails to arm a second still owes the first a disarm, and one that
 * armed neither must not send any on the way out.
 */
export class CaptureArms {
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private cadenceMs = heartbeatFor(CAPTURE_TTL_MS);
  private readonly held: CaptureArm[] = [];

  /** [note] is how a failed disarm reaches the operator. It is never fatal:
   *  each window lapses on its own, so a failed disarm costs one more capture
   *  window, never a stuck one. */
  constructor(private readonly note: (what: string, error: string) => void) {}

  /** Arm one capture, holding it for the heartbeat and the disarm only if the
   *  host said yes. */
  async arm(arm: CaptureArm): Promise<{ error: string | null; ttlMs: number }> {
    const res = await arm.set(true);
    if (res.error === null) this.held.push(arm);
    return res;
  }

  /** Narrow the cadence so it stays inside a window the host granted. */
  pace(ttlMs: number): void {
    this.cadenceMs = Math.min(this.cadenceMs, heartbeatFor(ttlMs));
  }

  /** Begin renewing everything held. Nothing armed means no interval at all —
   *  an unarmed run must not keep the process alive to renew nothing. */
  start(): void {
    if (this.held.length === 0) return;
    this.heartbeat = setInterval(() => {
      for (const arm of this.held) void arm.set(true);
    }, this.cadenceMs);
  }

  /**
   * Clear the heartbeat, then disarm everything still held, in the order it was
   * armed.
   *
   * The heartbeat is what holds an armed capture open, so ANY exit from a
   * watcher's stream must reach here — a throw out of the SSE parser or a broken
   * pipe on stdout otherwise leaves a phone-side capture, or this host's own
   * recording, armed with nobody left to disarm it.
   *
   * Each arm leaves the list BEFORE its round trip rather than after, because a
   * SIGINT-driven stop and the stream's own can be in flight together and
   * neither may send a second disarm for a capture the other already took.
   *
   * That drain is also the reason the `clearInterval` is about the TIMER rather
   * than about the captures: by the time an un-cleared interval next fires, the
   * list it renews is empty, so it renews nothing for the run that started it.
   * What it does instead is outlive that run — holding the event loop open, and
   * adopting whatever this object is asked to hold next.
   */
  async stop(): Promise<void> {
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;
    while (this.held.length > 0) {
      const arm = this.held.shift()!;
      const { error } = await arm.set(false);
      if (error) this.note(arm.what, error);
    }
  }
}

/**
 * Defer Ctrl-C until the arms are disarmed, running [before] first.
 *
 * A watcher's closing tally is most of why you ran it, so it must still print —
 * and the disarm is a round trip, so the exit is deferred until it settles.
 * Bounded: a host that has stopped answering must not hold the terminal, and
 * each capture's own TTL covers the disarm that never lands.
 *
 * Returns the detach. A caller's `finally` must run it before its own `stop()`,
 * or a stream that ended on its own leaves this handler displacing SIGINT's
 * default for the rest of the process.
 */
export function deferExitForDisarm(arms: CaptureArms, before: () => void): () => void {
  const onSigint = (): void => {
    before();
    // `.catch` before `.then`, not after: this handler has already displaced
    // SIGINT's default, so a rejected disarm (postControl's `res.json()` on a
    // half-shut host, say) that skipped the exit would strand the terminal with
    // no second Ctrl-C able to help it.
    void Promise.race([arms.stop(), new Promise((r) => setTimeout(r, 1500))])
      .catch(() => {})
      .then(() => process.exit(0));
  };
  process.on("SIGINT", onSigint);
  return () => process.off("SIGINT", onSigint);
}

/** Everything the handoff of a minted viewer link needs that the transport
 *  cannot know: which subcommand is speaking, and how the link is described. */
export interface ViewerLinkHandoff {
  /** The minted URL, fragment and all. */
  url: string;
  /** How the link is named in the notes — "capture viewer for 0.1.0 (pid 91)". */
  label: string;
  /** The window the host reported. Anything but a number falls back to the
   *  ticket's own two minutes rather than printing a figure nothing backs. */
  expiresInMs: unknown;
  /** False for `--no-open`: print the link rather than launching a browser. */
  open: boolean;
  /** The subcommand naming itself in an error — "antgrid watch". */
  command: string;
}

/** Mint-side done; put the link in front of the operator and report the exit
 *  code. A browser that cannot be launched is not a failure of the run — the
 *  link still works, so it is printed and the code stays 0. */
export function handOffViewerLink(handoff: ViewerLinkHandoff): number {
  const seconds = Math.round((typeof handoff.expiresInMs === "number" ? handoff.expiresInMs : 120_000) / 1000);
  if (!handoff.open) {
    console.error(`# ${handoff.label} — single-use, lapses in ${seconds}s`);
    console.log(handoff.url);
    return 0;
  }

  const how = openStandaloneWindow(handoff.url);
  if (how === "failed") {
    console.error(`${handoff.command}: could not launch a browser. Open this yourself:`);
    console.log(handoff.url);
    return 0;
  }
  console.error(`# ${handoff.label} opened in ${how === "window" ? "its own window" : "your browser"}`);
  // Deliberately not printed on the success path: the link is a credential, and
  // a scrollback is the one place it would outlive its own two minutes.
  console.error(`# the link was single-use and lapses in ${seconds}s — run this again for another`);
  return 0;
}
