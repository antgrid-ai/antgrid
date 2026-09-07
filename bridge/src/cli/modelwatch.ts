// `antgrid calls`: the headless model calls this machine spawns on the user's own
// provider accounts — a session title, the handler's decision, its extraction.
// Netwatch's sibling and its opposite in shape: that capture is a firehose of
// frames read seconds after the fact, this one is a few hundred calls a day where
// the one worth reading happened an hour ago and is three records long.
//
// Everything transport-shaped — reaching the loopback plane, the SSE parse, what
// that stream's control frames mean, the heartbeat that holds an arm open, the
// disarm that must outlive every exit, and the terminal's own colours and clock —
// is `./watch-transport`, shared with `antgrid watch`. What is here is what the
// two do not share: what a model call is, and how one reads.
import { appendFileSync } from "node:fs";
import { readHostFile, hostFilePath } from "../host-discovery";
import {
  CAPTURE_TTL_MS,
  CaptureArms,
  clock,
  COLOR,
  deferExitForDisarm,
  paint,
  parseJson,
  postControl,
  replayGaps,
  shedCount,
  sseEvents,
} from "./watch-transport";
import type { ModelCallEvent, ModelCallPrompt, ModelCallPurpose } from "../modelwatch";
import { MODEL_CALL_LOG_FIELDS } from "../modelwatch-log";

export interface ModelwatchCliOptions {
  /** Emit the raw records instead of the rendered attempts. */
  json?: boolean;
  /** Also append the records to this file as JSONL, whatever the render mode.
   *  Metadata only, always — see `exportable`. */
  export?: string;
  /** How many buffered RECORDS to replay before following. Records, not calls:
   *  see DEFAULT_LIMIT. */
  limit?: number;
  /** Print the buffered snapshot and exit rather than following. */
  follow?: boolean;
  /** ANTGRID_DIR override — a debug-build app runs under ~/.antgrid-dev. */
  dir?: string;
  /** Show only this kind of call. */
  purpose?: string;
  /**
   * Record the prompt parts the bridge itself authored — the scaffold, the
   * handler goal, a count for the backlog and a digest for the transcript — for
   * the life of this run. Metadata is always in the ring; nothing the user or
   * the agent wrote ever is unless someone asked out loud, which is what this
   * flag does.
   */
  prompts?: boolean;
  /**
   * Also record the transcript excerpt itself, and the model's answer with it.
   * The dangerous arm, and the reason it is a second flag rather than a level
   * of the first: what it admits is not ours — see the refusal text in
   * `runModelwatchCli` and `armContextCapture` in modelwatch.ts.
   */
  context?: boolean;
}

const PURPOSES: readonly ModelCallPurpose[] = ["title", "decision", "extraction"];

/**
 * How much of the ring to replay when nothing was asked for.
 *
 * Counted in RECORDS, and a call is three of them — the attempt starts, the
 * attempt ends, and the caller says what it made of the answer — with a retry
 * adding three more. So a reader who wants "the last fifty or so calls" needs a
 * figure several times that, and unlike netwatch's 200 there is no firehose
 * behind it: the ring holds a few hundred calls a day rather than a scrolling
 * build's worth of frames per second.
 */
const DEFAULT_LIMIT = 600;

/**
 * Below this, a retry cannot land, whatever the arithmetic says it is owed.
 *
 * A judge's two attempts share ONE budget (`runWithRetry` in handler/judge.ts),
 * so what the first leaves is the whole of what the second gets. The floor is
 * not a preference: every headless call pays process startup plus a vendor
 * preamble of twelve to twenty-three thousand tokens before it reads a word of
 * the prompt, and the fastest such call measured on a developer machine still
 * spent 2.6s in the API alone. Five seconds is therefore the generous reading of
 * "could this attempt possibly have finished", and a first attempt that leaves
 * less has silently made the retry decorative — which is exactly the thing this
 * feature exists to put on screen.
 */
const RETRY_FLOOR_MS = 5_000;

/**
 * Ceiling on attempts held open waiting for their outcome record.
 *
 * An attempt is rendered when the CALLER says what it made of the answer, which
 * lands within milliseconds of the spawn returning on every path that records
 * one — but "every path today" is not a bound, and this process is a watcher
 * someone leaves running for hours. Flushing the oldest keeps a missing outcome
 * costing one under-described row rather than unbounded memory.
 */
const MAX_PENDING_ATTEMPTS = 256;

/** Arm or disarm the host's capture of prompt text. Reports the window the host
 *  ACTUALLY granted rather than the one requested, because the host clamps and a
 *  heartbeat pacing itself off the request would let the dead man's switch lapse
 *  mid-run — taking the text already in the ring with it. */
async function setCaptureArms(
  host: { controlPort: number; token: string },
  arms: ("prompts" | "context")[],
  enabled: boolean,
): Promise<{ error: string | null; ttlMs: number; prompts?: boolean; context?: boolean }> {
  const { error, reply } = await postControl(
    host,
    { type: "modelwatch:arm", arms, enabled, ...(enabled ? { ttlMs: CAPTURE_TTL_MS } : {}) },
    "modelwatch",
  );
  const armed = reply?.ttlMs;
  return {
    error,
    ttlMs: typeof armed === "number" && armed > 0 ? armed : CAPTURE_TTL_MS,
    prompts: typeof reply?.prompts === "boolean" ? reply.prompts : undefined,
    context: typeof reply?.context === "boolean" ? reply.context : undefined,
  };
}

/**
 * Render one recorded field for a terminal.
 *
 * Half of what reaches here was written by a model: an `outcomeDetail` is a
 * parse error quoting the answer, and under the capture arms the answer itself
 * is on screen. A CLI's stdout can repaint or retitle the operator's window, so
 * C0/C1 come out and the length is capped again here even where the record site
 * already capped it.
 */
function field(value: unknown, max = 64): string {
  const s = typeof value === "string" ? value : String(value);
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\x00-\x1f\x7f-\x9f]/g, "").slice(0, max);
}

/** Multi-line captured text, sanitized per line so a newline survives and an
 *  escape sequence does not. */
function textLines(value: string, max: number): string[] {
  return value.split("\n").map((line) => field(line, max));
}

function duration(ms: number | undefined): string {
  if (ms === undefined || !Number.isFinite(ms)) return "—";
  if (Math.abs(ms) < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function tokens(n: number | undefined): string | null {
  if (n === undefined || !Number.isFinite(n)) return null;
  return n < 1000 ? String(n) : `${(n / 1000).toFixed(1)}k`;
}

/**
 * One attempt, folded together from the records that describe it.
 *
 * The recorder writes three: the spawn says an attempt started and how it
 * exited, and the CALLER — which is the only thing that knows whether the answer
 * was usable — says what became of it. Rendering them as three rows would put
 * the timing and the verdict of one model call on separate lines and leave the
 * reader joining them by eye, so they are joined here instead, on the key the
 * recorder already shares between them.
 */
interface Attempt {
  callId: string;
  attempt: number;
  purpose: string;
  /** When the attempt began — the first record's clock, never the last's, so
   *  rows read in the order the calls were made. */
  at: number;
  requestedTool: string;
  actualTool: string;
  reach: string;
  requestedModel?: string;
  actualModel?: string;
  terminalId?: string;
  wallMs?: number;
  apiMs?: number;
  budgetMs?: number;
  remainingMs?: number;
  exitCode?: number | null;
  timedOut?: boolean;
  outcome?: string;
  outcomeDetail?: string;
  promptChars?: number;
  stdoutChars?: number;
  prompt?: ModelCallPrompt;
  stdout?: string;
  usage?: ModelCallEvent["usage"];
  /** Whether an `end` record was ever seen. Distinguishes a call still in flight
   *  from one that exited without timings, which look identical field by field. */
  ended: boolean;
}

function attemptKey(event: ModelCallEvent): string {
  return `${event.callId}#${event.attempt}`;
}

/** The fields a later record may fill in. Named once because both types carry
 *  them and the fold below has to agree with the interface above. */
const FOLDED_FIELDS = [
  "requestedModel", "actualModel", "terminalId", "wallMs", "apiMs", "budgetMs",
  "remainingMs", "exitCode", "timedOut", "outcome", "outcomeDetail",
  "promptChars", "stdoutChars", "prompt", "stdout", "usage",
] as const satisfies readonly (keyof Attempt & keyof ModelCallEvent)[];

/** Fold one record into the attempt it describes. Later records win field by
 *  field, and an absent field never overwrites a present one — the three phases
 *  are additive by construction, and the outcome record carries only what the
 *  spawn could not know. */
function fold(into: Attempt | undefined, event: ModelCallEvent): Attempt {
  const base: Attempt = into ?? {
    callId: event.callId,
    attempt: event.attempt,
    purpose: event.purpose,
    at: event.at,
    requestedTool: event.requestedTool,
    actualTool: event.actualTool,
    reach: event.reach,
    ended: false,
  };
  const next: Attempt = { ...base, ended: base.ended || event.phase === "end" };
  const from = event as unknown as Record<string, unknown>;
  const into_ = next as unknown as Record<string, unknown>;
  for (const key of FOLDED_FIELDS) {
    if (from[key] !== undefined) into_[key] = from[key];
  }
  return next;
}

/** Which agent ran, and which one was asked for when they differ. A `need:
 *  "none"` call takes whichever installed agent can serve it, so a session on
 *  one vendor routinely bills a title to another; that borrow is invisible in
 *  every other record on the machine. */
function toolCell(a: Attempt): string {
  return a.requestedTool === a.actualTool
    ? field(a.actualTool, 20)
    // Wider than the column when both names are long, deliberately: a borrow is
    // rare and is the thing on the row worth reading, so it pushes the columns
    // right rather than being cut down to fit them.
    : `${field(a.requestedTool, 16)}→${field(a.actualTool, 16)}`;
}

/** What the vendor was asked to run. `default` is not a missing value: it is the
 *  call that named no model at all and therefore ran on whatever this machine's
 *  CLI defaults to — a three-word naming task on a frontier model, in the case
 *  that prompted this feature. */
function modelCell(a: Attempt): string {
  const requested = a.requestedModel ? field(a.requestedModel, 16) : "default";
  if (!a.actualModel || a.actualModel === a.requestedModel) return requested;
  // The two differ when the vendor's own home directory was swapped for a
  // scratch one and took the user's model selection with it.
  return `${requested}→${field(a.actualModel, 16)}`;
}

/**
 * Whether the caller ended up USING this attempt's answer.
 *
 * Matched on the outcome's words rather than enumerated, because the vocabulary
 * belongs to the callers (`note` in handler/judge.ts, the title path's own) and a
 * closed list here would silently classify the next verb they invent as a
 * success. Every failing leg any of them records names itself with one of these:
 * the answer would not parse, broke a stated rule, ran out of budget, hung, or
 * never ran at all.
 *
 * Two readers, and they must agree: the colour of the verdict, and whether the
 * leftover budget below describes a retry that was actually going to happen.
 */
function answerWasUsable(outcome: string): boolean {
  return !/fail|timeout|reject|unparse|exhaust|unavailable|abandon|no-judge/.test(outcome);
}

/** Whether this attempt's leftover budget had nobody waiting on it: the caller
 *  took the answer, so no retry was dispatched and none was denied. */
function retryWasMoot(a: Attempt): boolean {
  return a.outcome !== undefined && answerWasUsable(a.outcome);
}

/** The verdict, preferring what the caller made of the answer over how the
 *  process exited: a judge that answers perfectly and breaks a rule the prompt
 *  states exits 0, and "exit 0" is the least true thing that could be said
 *  about it. */
function outcomeCell(a: Attempt): { text: string; color: keyof typeof COLOR } {
  if (a.outcome) {
    return { text: field(a.outcome, 20), color: answerWasUsable(a.outcome) ? "green" : "yellow" };
  }
  if (a.timedOut) return { text: "timed out", color: "red" };
  if (!a.ended) return { text: "in flight", color: "cyan" };
  if (a.exitCode !== undefined && a.exitCode !== null && a.exitCode !== 0) {
    return { text: `exit ${a.exitCode}`, color: "yellow" };
  }
  return { text: "ran", color: "dim" };
}

/**
 * What this attempt left for the next one, in the words the arithmetic actually
 * has.
 *
 * Only the shared-budget callers record it, so its absence means "this call had
 * no retry to starve" rather than "plenty left". Printed on the row rather than
 * left to `--json` because it is the number the whole feature exists to surface:
 * nothing else on the machine says that a retry was already unreachable when it
 * was dispatched.
 *
 * An attempt whose answer the caller USED gets no note at all, however little it
 * left. The judge records the leftover on its success leg too (`note(1,
 * "parsed", { remainingMs })`), and it is worth having under `--json` — it is the
 * measurement that says whether the budget is set anywhere near the truth. But it
 * is not a starved retry, because there was no retry: reading it as one turns
 * every slow-and-correct judge into a red row, and a machine whose judge merely
 * takes most of its budget reports its every call as a dead retry. The headline
 * tally counts on the same rule, or the screen contradicts itself — "0 of them
 * retries" above "retries left unreachable 1".
 */
function retryBudgetNote(a: Attempt): { text: string; color: keyof typeof COLOR } | null {
  if (a.remainingMs === undefined || retryWasMoot(a)) return null;
  if (a.remainingMs <= 0) return { text: "nothing left for a retry", color: "red" };
  if (a.remainingMs < RETRY_FLOOR_MS) {
    return { text: `${duration(a.remainingMs)} left for the retry — unreachable`, color: "red" };
  }
  return { text: `${duration(a.remainingMs)} left for the retry`, color: "dim" };
}

function usageNote(a: Attempt): string | null {
  const u = a.usage;
  if (!u) return null;
  const parts: string[] = [];
  const inTok = tokens(u.inputTokens);
  const outTok = tokens(u.outputTokens);
  const cached = tokens(u.cacheReadTokens);
  if (inTok) parts.push(`in ${inTok}`);
  if (cached) parts.push(`cache ${cached}`);
  if (outTok) parts.push(`out ${outTok}`);
  // Tagged with its unit and never folded into anything: the vendors report
  // dollars, nothing at all, and fractional premium requests, so there is no
  // sum of two of these that means anything.
  if (u.money) parts.push(`${u.money.amount} ${field(u.money.unit, 20)}`);
  return parts.length > 0 ? parts.join(" · ") : null;
}

/** The captured text, indented under its row. Present only for the arms that
 *  were up when the call was recorded, which is why each part names itself
 *  rather than relying on position. */
function textBlock(a: Attempt, color: boolean): string[] {
  const out: string[] = [];
  const push = (label: string, value: string, max = 400): void => {
    const lines = textLines(value, max);
    out.push(`      ${paint(label.padEnd(9), "dim", color)}${lines[0] ?? ""}`);
    for (const line of lines.slice(1)) out.push(`      ${" ".repeat(9)}${line}`);
  };
  const p = a.prompt;
  if (p?.scaffold !== undefined) push("scaffold", p.scaffold);
  if (p?.goal !== undefined) push("goal", p.goal);
  // A count, never the text: the backlog is the user's own words to their agent
  // and no arm admits it.
  if (p?.backlogChars !== undefined) push("backlog", `${p.backlogChars} chars — never recorded`);
  if (p?.context) {
    // The digest answers the question a retry raises — was this the same context
    // as the attempt before it — with nothing to leak.
    push("context", `${p.context.sha256.slice(0, 12)}… ${p.context.chars} chars`);
  }
  if (p?.contextText !== undefined) push("ctx text", p.contextText);
  if (a.stdout !== undefined) push("answer", a.stdout);
  return out;
}

/**
 * One attempt as a row, with its retry indented under the attempt it retried.
 *
 * The `↳` and the shared call id are the whole of the grouping: a judge's two
 * attempts are one call against one budget, and rendered as two independent
 * rows they read as two calls — which is the misreading that hides a retry that
 * never had time to run.
 */
function renderAttempt(a: Attempt, color = false): string {
  const outcome = outcomeCell(a);
  const detail: string[] = [];
  const budget = retryBudgetNote(a);
  if (budget) detail.push(paint(budget.text, budget.color, color));
  if (a.outcomeDetail) detail.push(paint(field(a.outcomeDetail, 96), "yellow", color));
  if (a.reach === "unavailable") detail.push(paint("no headless entry", "yellow", color));
  // Zero characters back from a spawn that exited fine is its own diagnosis, and
  // it is invisible in every other column.
  if (a.ended && a.stdoutChars === 0) detail.push(paint("no output", "yellow", color));
  const usage = usageNote(a);
  if (usage) detail.push(paint(usage, "dim", color));
  if (a.apiMs !== undefined) detail.push(paint(`api ${duration(a.apiMs)}`, "dim", color));
  if (a.terminalId) detail.push(paint(`t:${field(a.terminalId, 8)}`, "dim", color));

  // Every cell is padded BEFORE it is painted: the escape sequences count toward
  // a string's length and nothing on screen counts toward its width, so padding
  // a painted cell aligns a colourless terminal and nothing else.
  const cols = [
    paint(clock(a.at), "dim", color),
    paint(field(a.callId, 8).padEnd(8), "dim", color),
    field(a.purpose, 10).padEnd(10),
    a.attempt === 1 ? " #1" : `↳#${a.attempt}`,
    toolCell(a).padEnd(20),
    modelCell(a).padEnd(16),
    // Wall against the bound this attempt was actually held to. On a retry that
    // bound IS what the previous row said was left, which is what makes the two
    // rows one story.
    paint(`${duration(a.wallMs).padStart(7)}/${duration(a.budgetMs)}`.padEnd(14), a.timedOut ? "red" : "dim", color),
    // Padded only when something follows it, so a row with nothing left to say
    // does not end in a column of trailing spaces.
    paint(detail.length > 0 ? outcome.text.padEnd(16) : outcome.text, outcome.color, color),
  ];
  const row = cols.join("  ");
  const line = detail.length > 0 ? `${row}  ${detail.join("  ")}` : row;
  return [line, ...textBlock(a, color)].join("\n");
}

/** Whether this record survives the purpose narrowing. No flag = every kind. */
function selected(event: ModelCallEvent, opts: ModelwatchCliOptions): boolean {
  return opts.purpose === undefined || event.purpose === opts.purpose;
}

/**
 * What `--export` is allowed to write: the durable feed's own field list, and
 * nothing this file decides for itself.
 *
 * Metadata only, unconditionally, for the reason that feed holds metadata only —
 * an export file is written to be pasted into a bug report, and a captured prompt
 * is the transcript and PTY scrollback of the session that produced it. The arms
 * put that text on the operator's own screen for the length of one run; a file
 * outlives the run, the window and the arm's own dead man's switch.
 *
 * An ALLOW-LIST, and borrowed rather than restated, because both halves matter.
 * A deny-list here (`const { prompt, stdout, ...rest } = event`) would write
 * `outcomeDetail` — the field modelwatch-log.ts excludes BY NAME, with the reason
 * spelled out at `MODEL_CALL_LOG_FIELDS`: its third producer is a Zod issue
 * quoting the judge's own JSON, and the judge is required to quote the transcript
 * back character for character. And it would keep writing whatever the record
 * gains next — the vendors' own `usage` envelopes being the obvious one — the
 * moment that field exists, with nobody editing this function. Borrowing the list rather than copying it is what keeps
 * this file and that one from disagreeing about which is true, since the docs
 * promise a reader they hold the same thing.
 *
 * `--json` is the mode that withholds nothing. That one goes to a pipe the
 * operator is watching, not to a file they will attach to a ticket a week later.
 */
function exportable(event: ModelCallEvent): string {
  const metadata: Record<string, unknown> = {};
  const from = event as unknown as Record<string, unknown>;
  for (const key of MODEL_CALL_LOG_FIELDS) {
    if (from[key] !== undefined) metadata[key] = from[key];
  }
  return JSON.stringify(metadata);
}

export async function runModelwatchCli(opts: ModelwatchCliOptions): Promise<number> {
  if (opts.purpose !== undefined && !PURPOSES.includes(opts.purpose as ModelCallPurpose)) {
    console.error(`antgrid calls: unknown --purpose "${opts.purpose}"; use ${PURPOSES.join(", ")}.`);
    return 1;
  }
  if (opts.dir) process.env.ANTGRID_DIR = opts.dir;

  const path = hostFilePath();
  const host = readHostFile(path);
  if (!host) {
    console.error(`antgrid calls: no running host found (looked in ${path}).`);
    console.error("Start the app or the bridge first. A debug-build app runs under");
    console.error("~/.antgrid-dev — point at it with --dir or ANTGRID_DIR.");
    return 1;
  }

  const color = Boolean(process.stdout.isTTY);
  const limit = opts.limit ?? DEFAULT_LIMIT;
  const follow = opts.follow !== false;
  // The arms record the FUTURE. With no stream to follow, the window would open
  // and close around a snapshot that was already in the ring before either verb
  // was sent — a silent no-op that reads as "this build captures no prompts".
  if ((opts.prompts || opts.context) && !follow) {
    console.error("antgrid calls: --prompts/--context need a live stream; drop --no-follow.");
    console.error("Text already in the ring is shown either way, for as long as its arm is up.");
    return 1;
  }

  const arms = new CaptureArms((what, err) => {
    if (!opts.json) console.error(paint(`# could not disarm ${what} (${err}); it lapses on its own`, "dim", color));
  });

  // Asking for the transcript arm asks for both. The transcript and the model's
  // answer are admitted only while the prompt arm is up as well
  // (`sessionTextArmed` in modelwatch.ts), so honouring `--context` literally
  // would arm the dangerous capture and then record nothing through it.
  const wanted: ("prompts" | "context")[] = opts.context ? ["prompts", "context"] : ["prompts"];
  // Read where the reply arrives rather than returned through `arm`, whose
  // contract is the window and nothing else: every re-arm the heartbeat sends
  // answers this too, and only the first one is worth telling the operator about.
  let contextArmed: boolean | undefined;
  if (opts.prompts || opts.context) {
    const what = opts.context ? "prompt and transcript capture" : "prompt capture";
    const { error, ttlMs } = await arms.arm({
      what,
      set: async (enabled) => {
        const res = await setCaptureArms(host, wanted, enabled);
        if (enabled) contextArmed = res.context;
        return res;
      },
    });
    if (error) {
      console.error(`antgrid calls: could not arm ${what} — ${error}`);
      await arms.stop();
      return 1;
    }
    arms.pace(ttlMs);
    // The reply re-reads both arms rather than echoing the request, so a host
    // that declined half of it says so here instead of leaving the operator
    // waiting for text that is never coming.
    if (opts.context && contextArmed === false) {
      console.error("antgrid calls: the host did not arm the transcript arm; rows will carry no transcript text.");
    }
    if (!opts.json) {
      // Two things an empty first screen would otherwise be blamed for. The
      // replayed rows above the live marker were recorded unarmed and carry no
      // text at all — a gap in the capture, not in the calls. And the disarm on
      // the way out does not merely stop recording: it takes the text already
      // recorded with it, because this ring is sized to hold days.
      console.error(paint(`# ${what} armed — calls from now carry text, truncated per field`, "dim", color));
      console.error(paint("# it is dropped again on exit, from the ring as well as from the future", "dim", color));
    }
  }
  arms.start();

  const url = `http://127.0.0.1:${host.controlPort}/modelwatch?limit=${limit}&follow=${follow ? "1" : "0"}`;
  let res: Response;
  try {
    res = await fetch(url, { headers: { authorization: `Bearer ${host.token}` } });
  } catch (err) {
    console.error(`antgrid calls: cannot reach host on 127.0.0.1:${host.controlPort} — ${(err as Error).message}`);
    console.error("host.json may be stale; the host writes a fresh one on every start.");
    await arms.stop();
    return 1;
  }
  if (!res.ok || !res.body) {
    console.error(`antgrid calls: host refused the model-call stream (HTTP ${res.status}).`);
    await arms.stop();
    return 1;
  }

  if (!opts.json) {
    const scope = opts.purpose ? `${opts.purpose} calls only` : "titles, decisions and extractions";
    console.error(paint(`# watching ${host.agentVersion} (pid ${host.pid}) — ${scope}`, "dim", color));
  }

  const pending = new Map<string, Attempt>();
  const calls = new Set<string>();
  const byPurpose = new Map<string, { attempts: number; wallMs: number }>();
  let retries = 0;
  let borrows = 0;
  let defaultModel = 0;
  let timeouts = 0;
  let starved = 0;
  let drops = 0;
  let replaying = true;
  let streamError: string | null = null;
  // A closed stdout — `| head`, or a pager quit — is the ordinary way to stop
  // reading, not a failure. Recorded rather than thrown because rows are also
  // printed from the flushes that run AFTER the loop, where an escaping EPIPE
  // would reject this function and take the caller's `process.exit` with it.
  let stdoutBroken = false;

  const emit = (a: Attempt): void => {
    calls.add(a.callId);
    const tally = byPurpose.get(a.purpose) ?? { attempts: 0, wallMs: 0 };
    tally.attempts++;
    tally.wallMs += a.wallMs ?? 0;
    byPurpose.set(a.purpose, tally);
    if (a.attempt > 1) retries++;
    if (a.requestedTool !== a.actualTool) borrows++;
    if (!a.requestedModel) defaultModel++;
    if (a.timedOut || a.outcome === "timeout") timeouts++;
    // Same gate as the row's own note, for the same reason: a first attempt the
    // caller was happy with starved nothing.
    if (a.remainingMs !== undefined && a.remainingMs < RETRY_FLOOR_MS && !retryWasMoot(a)) starved++;
    if (stdoutBroken) return;
    try {
      console.log(renderAttempt(a, color));
    } catch {
      stdoutBroken = true;
    }
  };

  const flush = (key: string): void => {
    const a = pending.get(key);
    if (!a) return;
    pending.delete(key);
    emit(a);
  };

  /** Oldest first, which is the order they were started in. */
  const flushAll = (): void => {
    for (const key of [...pending.keys()]) flush(key);
  };

  /**
   * The replay is over; print what it held, and keep what it did not finish.
   *
   * An attempt whose `start` was replayed but whose `end` has not arrived is a
   * spawn that was RUNNING when this reader attached — which is the case someone
   * runs this command for. Flushing it here would print it as an "in flight" row
   * and then fold its live `end` and `outcome` into a SECOND Attempt, so one
   * model call becomes two rows and two entries in every tally, the surviving one
   * stamped with the end record's clock instead of the start's, and everything
   * carried only on the `start` — `promptChars`, and the prompt parts the arms
   * admitted — stranded on the phantom.
   *
   * `ended` is the honest signal and it is not a guess: `runHeadless` records an
   * `end` on both its legs, including the one where the spawn never started, so
   * an attempt with none has not returned. The eviction that could otherwise
   * strand a `start` cannot: the ring evicts oldest-first, so a surviving `start`
   * means its `end` survived too if it was ever written. What is left over — an
   * attempt whose spawn returned inside the replay but whose caller's verdict did
   * not, a window of milliseconds — is flushed, and its outcome, if it does
   * arrive, opens a row of its own rather than silently rewriting a printed one.
   */
  const flushReplayed = (): void => {
    for (const [key, a] of [...pending.entries()]) if (a.ended) flush(key);
  };

  const summary = (): void => {
    if (opts.json) return;
    const attempts = [...byPurpose.values()].reduce((n, t) => n + t.attempts, 0);
    console.error("");
    console.error(paint(`# ${calls.size} calls, ${attempts} attempts, ${retries} of them retries`, "dim", color));
    for (const [purpose, tally] of [...byPurpose.entries()].sort((a, b) => b[1].attempts - a[1].attempts)) {
      console.error(paint(`#   ${purpose} ${tally.attempts} — ${duration(tally.wallMs)} of wall time`, "dim", color));
    }
    // The four numbers that are levers rather than trivia: a retry that could
    // not have run, a spawn billed to a vendor this session did not choose, a
    // call that named no model, and a budget that ran out.
    console.error(paint(`#   retries left unreachable ${starved}   borrowed ${borrows}   on the CLI's default model ${defaultModel}   timed out ${timeouts}`, "dim", color));
    if (drops > 0) console.error(paint(`#   ${drops} records dropped — this reader was behind the capture`, "yellow", color));
  };

  const detachInterrupt = deferExitForDisarm(arms, () => {
    flushAll();
    summary();
  });

  // The heartbeat is what holds an armed capture open, so ANY exit from this
  // loop must clear it — a throw out of the SSE parser or a broken pipe on
  // stdout otherwise leaves the interval renewing prompt capture on this host
  // forever, and keeps the process alive to keep renewing it.
  try {
    for await (const frame of sseEvents(res.body)) {
      if (frame.event === "replayed") {
        replaying = false;
        // A finished attempt held across the marker would print as though it had
        // just happened live; an unfinished one is a spawn still running, and
        // belongs to the rows below rather than to the history above.
        flushReplayed();
        if (!opts.json) {
          const notes = replayGaps(frame.data, "records");
          const note = notes.length > 0 ? ` (${notes.join("; ")})` : "";
          console.error(paint(`# --- live ---${note}`, "dim", color));
        }
        continue;
      }
      if (frame.event === "shed") {
        // A gap in what reached the screen, not in what the machine spawned.
        const dropped = shedCount(frame.data);
        drops += dropped;
        if (!opts.json) {
          console.error(paint(`# ${dropped} records dropped — this reader is behind the capture`, "yellow", color));
        }
        continue;
      }
      const event = parseJson<ModelCallEvent>(frame.data);
      if (!event || typeof event.callId !== "string") continue;
      if (!selected(event, opts)) continue;

      if (opts.export) {
        try {
          appendFileSync(opts.export, `${exportable(event)}\n`);
        } catch (err) {
          console.error(`antgrid calls: export failed — ${(err as Error).message}`);
          return 1;
        }
      }

      if (opts.json) {
        // The records as recorded, prompt text included: this is the mode a
        // reader pipes into a tool of their own, and holding a record back to
        // join it to a sibling would be this CLI deciding what that tool sees.
        try {
          console.log(JSON.stringify(event));
        } catch {
          break;
        }
        continue;
      }
      const key = attemptKey(event);
      pending.set(key, fold(pending.get(key), event));
      // The caller's verdict is the last word on an attempt, so its arrival is
      // what completes the row.
      if (event.phase === "outcome") flush(key);
      while (pending.size > MAX_PENDING_ATTEMPTS) flush(pending.keys().next().value!);
      if (stdoutBroken) break;
    }
  } catch (err) {
    // The host going away is the ordinary way a watcher session ends — a
    // restart, an app quit, a `taskkill` — and the socket reports it by
    // REJECTING the read rather than by ending the stream, so without this the
    // ECONNRESET escapes and takes the closing tally with it. That tally is most
    // of why the command was run: the counts, and every attempt still held
    // waiting for its outcome, are the run's whole output and are lost with it.
    streamError = (err as Error).message;
  } finally {
    detachInterrupt();
    await arms.stop();
  }
  if (streamError) console.error(`antgrid calls: the model-call stream ended — ${streamError}`);
  else if (replaying) console.error("antgrid calls: stream ended before replay completed.");
  flushAll();
  summary();
  return 0;
}
