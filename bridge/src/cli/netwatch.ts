import { appendFileSync, readFileSync } from "node:fs";
import { readHostFile, hostFilePath } from "../host-discovery";
import { NETWATCH_BODY_MAX_CHARS, type NetwatchEvent } from "../netwatch";

export interface NetwatchCliOptions {
  /** Emit raw JSONL instead of the rendered table. */
  json?: boolean;
  /** Also append raw JSONL to this file, whatever the render mode. */
  export?: string;
  /** How many buffered events to replay before following. */
  limit?: number;
  /** Snapshot and exit rather than following. */
  follow?: boolean;
  /** ANTGRID_DIR override — a debug-build app runs under ~/.antgrid-dev. */
  dir?: string;
  /**
   * Merge an app-side capture (`<ANTGRID_DIR>/netwatch.log`) against this
   * host's, pairing frames by id. Retrospective by construction, so it implies
   * `--no-follow`.
   */
  join?: string;
  /**
   * Ask the CONNECTED app to capture its own side and ship it here, so the live
   * stream carries both endpoints with no file to merge. This is the only
   * control surface a phone has — it reads no environment and shows no UI.
   */
  remote?: boolean;
  /**
   * Narrow the stream to one transport. Neither flag shows both, which is the
   * only reading that fits a machine running an app on loopback and a phone
   * over the relay at the same time; the two together is refused.
   */
  local?: boolean;
  relay?: boolean;
  /**
   * Record each loopback frame's plaintext for the duration of this run.
   * Metadata is always in the ring; a payload never is unless someone asked for
   * it out loud, which is what this flag does.
   */
  bodies?: boolean;
}

/**
 * Dead-man switch on an armed capture, and the heartbeat that holds it open.
 *
 * Both endpoints disarm themselves when the window lapses — the app for a
 * remote capture, this host for body recording — so a watcher killed with
 * SIGKILL, or a laptop that closes mid-session, cannot leave either one
 * recording indefinitely. The heartbeat is well inside the window so a single
 * dropped re-arm costs nothing.
 */
const CAPTURE_TTL_MS = 300_000;

/** The renewal cadence a window of `ttlMs` demands. The window an arm actually
 *  gets is the host's to decide (it clamps), so the cadence is derived from the
 *  answer rather than fixed — a capture shortened behind the watcher's back
 *  would otherwise lapse under re-arms that believed they were early. */
function heartbeatFor(ttlMs: number): number {
  return Math.max(1_000, Math.floor(ttlMs * 0.4));
}

/** One control verb at the loopback plane. `error` is null on success — the
 *  caller decides whether a failure is fatal (arming) or worth only a note (the
 *  disarm on the way out). */
async function postControl(
  host: { controlPort: number; token: string },
  verb: Record<string, unknown>,
): Promise<{ error: string | null; reply?: Record<string, unknown> }> {
  let res: Response;
  try {
    res = await fetch(`http://127.0.0.1:${host.controlPort}/control`, {
      method: "POST",
      headers: { authorization: `Bearer ${host.token}`, "content-type": "application/json" },
      body: JSON.stringify({ id: `netwatch-${Date.now()}`, ...verb }),
    });
  } catch (err) {
    return { error: (err as Error).message };
  }
  if (!res.ok) return { error: `HTTP ${res.status}` };
  const body = (await res.json()) as { ok: boolean; error?: { message?: string } } & Record<string, unknown>;
  return body.ok ? { error: null, reply: body } : { error: body.error?.message ?? "refused" };
}

/** Arm or disarm the connected app's capture. */
async function setRemoteCapture(
  host: { controlPort: number; token: string },
  enabled: boolean,
): Promise<string | null> {
  const { error } = await postControl(host, {
    type: "netwatch:remote",
    enabled,
    ...(enabled ? { ttlMs: CAPTURE_TTL_MS } : {}),
  });
  return error;
}

/** Arm or disarm plaintext recording for this host's loopback frames. Metadata
 *  is recorded either way and no verb turns it off, so `bodies` is the whole
 *  switch. Reports the window the host actually armed, which is what the
 *  heartbeat has to stay inside. */
async function setLocalBodies(
  host: { controlPort: number; token: string },
  bodies: boolean,
): Promise<{ error: string | null; ttlMs: number }> {
  const { error, reply } = await postControl(host, { type: "netwatch:local", bodies, ttlMs: CAPTURE_TTL_MS });
  const armed = reply?.ttlMs;
  return { error, ttlMs: typeof armed === "number" && armed > 0 ? armed : CAPTURE_TTL_MS };
}

const COLOR = {
  dim: "\u001b[2m",
  red: "\u001b[31m",
  yellow: "\u001b[33m",
  cyan: "\u001b[36m",
  green: "\u001b[32m",
  reset: "\u001b[0m",
};

function paint(text: string, color: keyof typeof COLOR, enabled: boolean): string {
  return enabled ? `${COLOR[color]}${text}${COLOR.reset}` : text;
}

function clock(at: number): string {
  const d = new Date(at);
  const p = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

function bytes(n: number | undefined): string {
  if (n === undefined) return "";
  if (n < 1024) return `${n}B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)}K`;
  return `${(n / (1024 * 1024)).toFixed(1)}M`;
}

/**
 * Render one peer-supplied field for a terminal.
 *
 * Everything but this bridge's own events reaches here verbatim: `ingestRemote`
 * passes a remote app's field set through unpoliced on purpose (a newer app may
 * record a field this bridge has no name for), so a field can be any JSON value
 * and can hold escape sequences. Coercing keeps a non-string from throwing
 * mid-stream on `.slice`, and dropping C0/C1 keeps a capture from repainting or
 * retitling the operator's terminal.
 */
function field(value: unknown, max = 64): string {
  const s = typeof value === "string" ? value : String(value);
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\x00-\x1f\x7f-\x9f]/g, "").slice(0, max);
}

function detailText(event: NetwatchEvent): string {
  const parts: string[] = [];
  if (event.streamId) parts.push(`s:${field(event.streamId, 8)}`);
  if (event.reason) parts.push(field(event.reason));
  for (const [k, v] of Object.entries(event.detail ?? {})) parts.push(`${field(k, 24)}=${field(v)}`);
  return parts.join(" ");
}

/**
 * Which wire carried this. An event that names no transport is read as relay:
 * the field postdates the relay-only capture, and everything that can reach
 * this process without it — an older host's ring, an app's own capture shipped
 * in by `--remote` — got here over the relay by construction.
 */
function transportOf(event: NetwatchEvent): "relay" | "local" {
  return event.transport === "local" ? "local" : "relay";
}

/** Whether this event survives the transport narrowing. Neither flag = both. */
function selected(event: NetwatchEvent, opts: NetwatchCliOptions): boolean {
  if (opts.local) return transportOf(event) === "local";
  if (opts.relay) return transportOf(event) === "relay";
  return true;
}

/**
 * The frame's own plaintext, on its own indented line under the row.
 *
 * It goes through the same sanitizer as every other peer-supplied field — a
 * body is the LEAST trusted thing in the capture, and an unsanitized one is an
 * escape sequence straight into the operator's terminal — and is capped again
 * here despite `captureBody` having capped it at the record site, because
 * `ingestRemote` admits a remote app's field set unpoliced.
 */
function bodyLine(event: NetwatchEvent, color: boolean): string | null {
  if (event.body === undefined) return null;
  return `    ${paint(field(event.body, NETWATCH_BODY_MAX_CHARS), "dim", color)}`;
}

/** The columns both views render identically. Only the leading clock/origin
 *  pair and the arrow's colour differ between them. */
function frameColumns(event: NetwatchEvent, color: boolean): string[] {
  const transport = transportOf(event);
  return [
    // Relay is the dimmed half: a desktop machine carries both wires at once,
    // and loopback is the one no other column would hint at — the channel,
    // kind and size of a local frame all read like a relay frame's.
    transport === "local" ? "local" : paint("relay", "dim", color),
    (event.channel === "preview" ? "prev" : event.channel === "control" ? "ctrl" : "—").padEnd(4),
    (event.kind === "drop" ? "DROP" : field(event.kind, 9)).padEnd(9),
    bytes(event.bytes).padStart(7),
    field(event.frameId ?? "", 12).padEnd(12),
    field(event.msgType ?? "", 40),
  ];
}

/** [showOrigin] is off unless a remote capture is armed: with one endpoint
 *  recording there is nothing to disambiguate, and a constant "brg" column
 *  would be a word per line saying what the reader already knows. */
export function renderEvent(event: NetwatchEvent, color = false, showOrigin = false): string {
  const drop = event.kind === "drop";
  const arrow = drop ? "x" : event.dir === "tx" ? "->" : "<-";
  const cols = [
    paint(clock(event.at), "dim", color),
    ...(showOrigin ? [paint(event.origin === "app" ? "app" : "brg", "dim", color)] : []),
    paint(`${arrow} ${event.dir}`, drop ? "red" : event.dir === "tx" ? "cyan" : "green", color).padEnd(
      color ? 14 : 5,
    ),
    ...frameColumns(event, color),
  ];
  const detail = detailText(event);
  const row = cols.join("  ");
  const line = detail ? `${row}  ${paint(detail, drop ? "yellow" : "dim", color)}` : row;
  const body = bodyLine(event, color);
  return body ? `${line}\n${body}` : line;
}

function parseJson<T>(raw: string): T | null {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

/** Parses an SSE byte stream into whole events. */
async function* sseEvents(body: ReadableStream<Uint8Array>): AsyncGenerator<{ event?: string; data: string }> {
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

/** Where an event was captured. The bridge stamps nothing, so a missing
 *  `origin` is its own — see the app's `NetwatchEvent.toJson`. */
type Origin = "app" | "brg";

/** How an event fared against the other endpoint's capture. `na` is not a
 *  failure: a drop never crossed the socket and a control frame carries no id,
 *  so neither can be paired even in a perfect capture. Counting those as
 *  matches would quietly flatter every report. */
type Verdict = "matched" | "lost" | "unpaired" | "outside" | "na";

const VERDICT_NOTE: Record<Verdict, string> = {
  matched: "",
  na: "",
  lost: "never arrived",
  unpaired: "sender not captured",
  outside: "outside capture overlap",
};

function renderJoinedRow(
  event: NetwatchEvent,
  origin: Origin,
  note: string,
  color: boolean,
): string {
  const drop = event.kind === "drop";
  const arrow = drop ? "x" : event.dir === "tx" ? "->" : "<-";
  const cols = [
    paint(clock(event.at), "dim", color),
    paint(origin, origin === "app" ? "cyan" : "green", color),
    paint(`${arrow} ${event.dir}`, drop ? "red" : "dim", color).padEnd(color ? 14 : 5),
    ...frameColumns(event, color),
  ];
  const detail = [detailText(event), note].filter(Boolean).join("  ");
  const row = cols.join("  ");
  const line = detail ? `${row}  ${paint(detail, drop || note ? "yellow" : "dim", color)}` : row;
  const body = bodyLine(event, color);
  return body ? `${line}\n${body}` : line;
}

/** Reads an app-side capture. Tolerates a partial trailing line: the writer
 *  appends in batches and may be running while this reads. */
function readAppCapture(path: string): NetwatchEvent[] | null {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (err) {
    console.error(`antgrid watch: cannot read ${path} — ${(err as Error).message}`);
    console.error("The app writes it only when ANTGRID_NETWATCH is set in its environment.");
    return null;
  }
  const events: NetwatchEvent[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line) as NetwatchEvent);
    } catch {
      // Torn last line, or a rotated file's boundary. Skip it.
    }
  }
  return events;
}

async function fetchBridgeSnapshot(
  controlPort: number,
  token: string,
  limit: number,
): Promise<NetwatchEvent[] | null> {
  let res: Response;
  try {
    res = await fetch(`http://127.0.0.1:${controlPort}/netwatch?limit=${limit}&follow=0`, {
      headers: { authorization: `Bearer ${token}` },
    });
  } catch (err) {
    console.error(`antgrid watch: cannot reach host on 127.0.0.1:${controlPort} — ${(err as Error).message}`);
    return null;
  }
  if (!res.ok || !res.body) {
    console.error(`antgrid watch: host refused the capture stream (HTTP ${res.status}).`);
    return null;
  }
  const events: NetwatchEvent[] = [];
  for await (const frame of sseEvents(res.body)) {
    if (frame.event === "replayed") continue;
    try {
      events.push(JSON.parse(frame.data) as NetwatchEvent);
    } catch {
      // Ignore a malformed line rather than abandon the whole capture.
    }
  }
  return events;
}

/**
 * How far back from `now` a frame is not yet expected to be on disk. The app
 * holds each event briefly so its type can be filled in, then its sink batches
 * the write — so the newest frames are legitimately absent from the file, and
 * calling them lost would invent a fault on every single run.
 */
const SETTLE_MS = 1000;

/**
 * Pairs the two captures on frame id.
 *
 * A sealed frame's id is its AES-GCM nonce, which the relay forwards
 * untouched — so the SAME id appears as `tx` on the sender and `rx` on the
 * receiver, and that is the entire join. What it buys is the question the
 * route header cannot answer: not "was something dropped" but "which one".
 *
 * A frame can only be called lost inside the window both captures actually
 * cover. That window's END is not the last event either side recorded — a quiet
 * capture is still a running one — but simply now, because both halves are read
 * live: the ring is fetched over the control plane and the file is read off
 * disk, in this process, at this moment. What IS truncated is the START: the
 * ring evicts and the file rotates, so whichever capture reaches furthest back
 * still cannot vouch for the other's earlier frames.
 */
export function joinCaptures(
  app: NetwatchEvent[],
  bridge: NetwatchEvent[],
  now: number = Date.now(),
): { rows: { event: NetwatchEvent; origin: Origin; verdict: Verdict; deltaMs?: number }[]; overlap: [number, number] | null } {
  const earliest = (xs: NetwatchEvent[]): number | null =>
    xs.length === 0 ? null : Math.min(...xs.map((e) => e.at));
  const a = earliest(app);
  const b = earliest(bridge);
  const start = a !== null && b !== null ? Math.max(a, b) : null;
  const end = now - SETTLE_MS;
  const overlap: [number, number] | null =
    start !== null && start <= end ? [start, end] : null;

  // A drop never crossed the socket, so it has no counterpart by definition and
  // is excluded from the index — otherwise a dropped send would "match" the
  // receiver's unrelated frame of the same id, which cannot happen but would be
  // a silent lie if it did.
  const index = new Map<string, NetwatchEvent[]>();
  const add = (e: NetwatchEvent): void => {
    if (!e.frameId || e.kind === "drop") return;
    const bucket = index.get(e.frameId);
    if (bucket) bucket.push(e);
    else index.set(e.frameId, [e]);
  };
  for (const e of app) add(e);
  for (const e of bridge) add(e);

  const rows = [...app.map((e) => ({ e, origin: "app" as Origin })), ...bridge.map((e) => ({ e, origin: "brg" as Origin }))]
    .sort((x, y) => x.e.at - y.e.at || x.e.seq - y.e.seq)
    .map(({ e, origin }) => {
      if (!e.frameId || e.kind === "drop") return { event: e, origin, verdict: "na" as Verdict };
      const peer = (index.get(e.frameId) ?? []).find((o) => o !== e && o.dir !== e.dir);
      if (peer) {
        return {
          event: e,
          origin,
          verdict: "matched" as Verdict,
          // Only meaningful on the receiving half of a pair, and only because
          // both captures come off one machine's clock in the desktop case.
          deltaMs: e.dir === "rx" ? e.at - peer.at : undefined,
        };
      }
      const inOverlap = overlap !== null && e.at >= overlap[0] && e.at <= overlap[1];
      if (!inOverlap) return { event: e, origin, verdict: "outside" as Verdict };
      return { event: e, origin, verdict: (e.dir === "tx" ? "lost" : "unpaired") as Verdict };
    });

  return { rows, overlap };
}

async function runNetwatchJoin(
  opts: NetwatchCliOptions,
  host: { controlPort: number; token: string },
): Promise<number> {
  const app = readAppCapture(opts.join!);
  if (!app) return 1;
  const bridge = await fetchBridgeSnapshot(host.controlPort, host.token, opts.limit ?? 4096);
  if (!bridge) return 1;

  // A join with no transport named is RELAY, not both — the one place the
  // filter's default differs from the live stream's. An app-side capture file
  // is relay traffic by construction, so a loopback frame in the host's half
  // has no counterpart to find and would be verdicted `lost` on every run of a
  // machine that also has a desktop app attached.
  const scoped: NetwatchCliOptions = opts.local ? opts : { ...opts, relay: true };
  const appRows = app.filter((e) => selected(e, scoped));
  const bridgeRows = bridge.filter((e) => selected(e, scoped));

  const color = Boolean(process.stdout.isTTY);
  const { rows, overlap } = joinCaptures(appRows, bridgeRows);
  const tally: Record<Verdict, number> = { matched: 0, lost: 0, unpaired: 0, outside: 0, na: 0 };

  for (const row of rows) {
    tally[row.verdict]++;
    // The verdict and delta are the part of a join that cannot be recomputed
    // later — once the ring has evicted and the app file has rotated, the
    // pairing is gone — so --export carries the JOINED row, not the bare event.
    const raw = JSON.stringify({ ...row.event, origin: row.origin, verdict: row.verdict, deltaMs: row.deltaMs });
    if (opts.export) {
      try {
        appendFileSync(opts.export, `${raw}\n`);
      } catch (err) {
        console.error(`antgrid watch: export failed — ${(err as Error).message}`);
        return 1;
      }
    }
    if (opts.json) {
      console.log(raw);
      continue;
    }
    const note =
      row.deltaMs !== undefined
        ? `+${row.deltaMs}ms`
        : VERDICT_NOTE[row.verdict] === ""
          ? ""
          : `${row.verdict === "lost" ? "✗" : "?"} ${VERDICT_NOTE[row.verdict]}`;
    console.log(renderJoinedRow(row.event, row.origin, note, color));
  }

  if (opts.json) return 0;
  console.error("");
  console.error(
    paint(
      `# ${appRows.length} app events joined against ${bridgeRows.length} host events ` +
        `(${scoped.local ? "loopback" : "relay"} frames only)`,
      "dim",
      color,
    ),
  );
  console.error(
    paint(
      overlap
        ? `# judged from ${clock(overlap[0])} (where the shorter capture starts) ` +
          `up to ${clock(overlap[1])} — both are live, less 1s for frames still buffered`
        : "# the two captures share no window — nothing here can be paired",
      "dim",
      color,
    ),
  );
  console.error(
    paint(
      `#   matched ${tally.matched}   lost ${tally.lost}   ` +
        `sender-not-captured ${tally.unpaired}   outside-overlap ${tally.outside}   ` +
        `unpairable ${tally.na}`,
      "dim",
      color,
    ),
  );
  return 0;
}

export async function runNetwatchCli(opts: NetwatchCliOptions): Promise<number> {
  // Two narrowings of one field with nothing in the intersection. Showing both
  // transports is already what asking for neither means, so the pair has no
  // reading left to honour.
  if (opts.local && opts.relay) {
    console.error("antgrid watch: --local and --relay are alternatives; omit both to see every transport.");
    return 1;
  }
  if (opts.dir) process.env.ANTGRID_DIR = opts.dir;

  const path = hostFilePath();
  const host = readHostFile(path);
  if (!host) {
    console.error(`antgrid watch: no running host found (looked in ${path}).`);
    console.error("Start the app or the bridge first. A debug-build app runs under");
    console.error("~/.antgrid-dev — point at it with --dir or ANTGRID_DIR.");
    return 1;
  }

  if (opts.join) {
    // A phone writes no netwatch.log — hostDir() resolves from USERPROFILE/HOME
    // — so the two flags answer the same question by paths that cannot combine:
    // --remote merges in the ring, --join merges two files after the fact.
    if (opts.remote) {
      console.error("antgrid watch: --remote and --join are alternatives; --remote already merges both halves live.");
      return 1;
    }
    // A join reads history, and arming records the future — the window would
    // open and close inside the same snapshot, so the flag can only ever be a
    // silent no-op here. Bodies a live run already put in the ring still show.
    if (opts.bodies) {
      console.error("antgrid watch: --bodies has nothing to arm for --join; it merges captures that already exist.");
      return 1;
    }
    return runNetwatchJoin(opts, host);
  }

  const color = Boolean(process.stdout.isTTY);
  const limit = opts.limit ?? 200;
  const follow = opts.follow !== false;
  // Same alternatives-that-cannot-combine refusal as --join above: a remote arm
  // is not retrospective (the app installs its tap on receipt), so a snapshot
  // taken immediately after it can only ever hold bridge-side history — and the
  // disarm on the way out lands before the app's first batch could arrive.
  if (opts.remote && !follow) {
    console.error("antgrid watch: --remote needs a live stream; drop --no-follow, or use --join to merge an existing app capture.");
    return 1;
  }
  // Bodies are not retrospective either: the arm lands after the snapshot it
  // would have filled was already in the ring, and the disarm on the way out
  // lands before anything else could be recorded.
  if (opts.bodies && !follow) {
    console.error("antgrid watch: --bodies needs a live stream; drop --no-follow. Bodies already in the ring are shown either way.");
    return 1;
  }
  const url =
    `http://127.0.0.1:${host.controlPort}/netwatch` +
    `?limit=${limit}&follow=${follow ? "1" : "0"}`;

  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let heartbeatMs = heartbeatFor(CAPTURE_TTL_MS);
  // What is actually armed, not what was asked for: a run that arms the app and
  // then fails to arm bodies still owes the app a disarm, and one that armed
  // neither must not send two on the way out.
  let remoteArmed = false;
  let bodiesArmed = false;
  const stopCaptures = async (): Promise<void> => {
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = null;
    // Not fatal: each window lapses on its own, so a failed disarm costs one
    // more capture window, never a stuck one.
    const note = (what: string, err: string): void => {
      if (!opts.json) console.error(paint(`# could not disarm ${what} (${err}); it lapses on its own`, "dim", color));
    };
    if (remoteArmed) {
      remoteArmed = false;
      const err = await setRemoteCapture(host, false);
      if (err) note("the app's capture", err);
    }
    if (bodiesArmed) {
      bodiesArmed = false;
      const { error } = await setLocalBodies(host, false);
      if (error) note("body capture", error);
    }
  };

  if (opts.remote) {
    const err = await setRemoteCapture(host, true);
    if (err) {
      console.error(`antgrid watch: could not arm the app's capture — ${err}`);
      console.error("An app must be connected to this machine over the relay for --remote to reach anything.");
      return 1;
    }
    remoteArmed = true;
    // A remote capture is not retrospective: the app installs its tap on
    // receipt, so nothing before this line exists on that side. Say so, rather
    // than let an empty first screen read as a broken connection.
    if (!opts.json) {
      console.error(paint("# remote capture armed — the app records from now, not retrospectively", "dim", color));
    }
  }
  if (opts.bodies) {
    const { error, ttlMs } = await setLocalBodies(host, true);
    if (error) {
      console.error(`antgrid watch: could not arm body capture — ${error}`);
      await stopCaptures();
      return 1;
    }
    bodiesArmed = true;
    heartbeatMs = Math.min(heartbeatMs, heartbeatFor(ttlMs));
    // Same non-retrospection as a remote arm, and the same reason for saying
    // it: the replayed frames above the live marker were recorded unarmed and
    // carry no plaintext, which is a gap in the capture rather than in the
    // traffic.
    if (!opts.json) {
      console.error(paint("# bodies armed — loopback frames from now carry their plaintext, truncated per frame", "dim", color));
    }
  }
  if (remoteArmed || bodiesArmed) {
    heartbeat = setInterval(() => {
      if (remoteArmed) void setRemoteCapture(host, true);
      if (bodiesArmed) void setLocalBodies(host, true);
    }, heartbeatMs);
  }

  let res: Response;
  try {
    res = await fetch(url, { headers: { authorization: `Bearer ${host.token}` } });
  } catch (err) {
    console.error(`antgrid watch: cannot reach host on 127.0.0.1:${host.controlPort} — ${(err as Error).message}`);
    console.error("host.json may be stale; the host writes a fresh one on every start.");
    await stopCaptures();
    return 1;
  }
  if (!res.ok || !res.body) {
    console.error(`antgrid watch: host refused the capture stream (HTTP ${res.status}).`);
    await stopCaptures();
    return 1;
  }

  const counts = new Map<string, number>();
  let drops = 0;
  let replaying = true;

  if (!opts.json) {
    // What this invocation is showing, said plainly: the ring holds both wires,
    // so an empty screen under a filter means that transport was quiet, not
    // that the capture is broken — and a reader who does not know a filter is
    // narrowing the stream has no way to tell those apart.
    const scope = opts.local
      ? "loopback frames only; relay frames are still recorded, --local hides them"
      : opts.relay
        ? "relay frames only; loopback frames are still recorded, --relay hides them"
        : "relay frames and the loopback socket the desktop app rides";
    console.error(paint(`# watching ${host.agentVersion} (pid ${host.pid}) — ${scope}`, "dim", color));
  }

  const summary = (): void => {
    if (opts.json) return;
    const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12);
    console.error("");
    console.error(paint(`# ${[...counts.values()].reduce((a, b) => a + b, 0)} frames, ${drops} dropped`, "dim", color));
    for (const [key, n] of ranked) console.error(paint(`#   ${key} ${n}`, "dim", color));
  };

  // Ctrl-C must still print the tally — the counts are most of why you ran it —
  // and must still disarm, which is a round trip, so the exit is deferred until
  // it settles. Bounded: a host that has stopped answering must not hold the
  // terminal, and each capture's own TTL covers the disarm that never lands.
  const onSigint = (): void => {
    summary();
    void Promise.race([stopCaptures(), new Promise((r) => setTimeout(r, 1500))]).then(() => process.exit(0));
  };
  process.on("SIGINT", onSigint);

  // The heartbeat is what holds an armed capture open, so ANY exit from this
  // loop must clear it — a throw out of the SSE parser or a broken pipe on
  // stdout otherwise leaves the interval renewing a phone-side capture, or this
  // host's body recording, forever, and keeps the process alive to keep
  // renewing it.
  try {
    for await (const frame of sseEvents(res.body)) {
      if (frame.event === "replayed") {
        replaying = false;
        if (!opts.json) {
          const meta = parseJson<{ evicted?: number; buffered?: number; replayed?: number }>(frame.data);
          const notes: string[] = [];
          if (meta && (meta.evicted ?? 0) > 0) notes.push(`${meta.evicted} older events already evicted`);
          // A short replay is not the same blind spot as an eviction and has its
          // own remedy (raise --limit), so it has to say which one happened.
          if (meta && (meta.replayed ?? 0) < (meta.buffered ?? 0)) {
            notes.push(`${(meta.buffered ?? 0) - (meta.replayed ?? 0)} buffered events not replayed — raise --limit`);
          }
          const note = notes.length > 0 ? ` (${notes.join("; ")})` : "";
          console.error(paint(`# --- live ---${note}`, "dim", color));
        }
        continue;
      }
      const event = parseJson<NetwatchEvent>(frame.data);
      if (!event) continue;
      // Before the tally and the export, both of which are about what this run
      // was asked to show: a filtered run's summary must count the same frames
      // its rows do, and its export must be a file it can be re-read from.
      if (!selected(event, opts)) continue;

      // Split the tally by endpoint or by transport only when both are in play
      // — otherwise every line would carry the same prefix.
      const key =
        `${opts.remote ? `${event.origin ?? "brg"} ` : ""}` +
        `${opts.local || opts.relay ? "" : `${transportOf(event)} `}` +
        `${event.dir} ${event.msgType ?? event.kind}`;
      counts.set(key, (counts.get(key) ?? 0) + 1);
      if (event.kind === "drop") drops++;

      const raw = JSON.stringify(event);
      if (opts.export) {
        try {
          appendFileSync(opts.export, `${raw}\n`);
        } catch (err) {
          console.error(`antgrid watch: export failed — ${(err as Error).message}`);
          return 1;
        }
      }
      console.log(opts.json ? raw : renderEvent(event, color, opts.remote === true));
    }
  } finally {
    process.off("SIGINT", onSigint);
    await stopCaptures();
  }
  if (replaying) console.error("antgrid watch: stream ended before replay completed.");
  summary();
  return 0;
}
