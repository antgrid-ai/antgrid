import { createHash } from "node:crypto";

/** Why the bridge spawned a model. Not derivable inside the spawn itself — the
 *  function that runs it is handed an argv and knows nothing about the caller. */
export type ModelCallPurpose = "title" | "decision" | "extraction";

/**
 * Which record this is:
 *   - `start`   — an attempt is about to spawn
 *   - `end`     — that attempt exited, with its timings
 *   - `outcome` — what the CALLER made of the answer, which the spawn cannot know
 */
export type ModelCallPhase = "start" | "end" | "outcome";

/**
 * The prompt recorded as NAMED PARTS rather than as the built string.
 *
 * Netwatch can capture a whole frame body because frames are typed and
 * `BODY_REDACTED_MESSAGE_TYPES` is one checkable list. A prompt has no type: a
 * decision prompt carries thousands of characters of transcript and PTY
 * scrollback and can hold a pasted key, an `.env` the agent opened, or a
 * password typed at a PTY prompt. No list makes flat prompt capture safe, so the
 * parts are recorded under per-part policy instead — text for the parts we
 * authored, a count or a digest for the parts the user and the agent did.
 */
export interface ModelCallPrompt {
  /** Prompt text we wrote ourselves, so it is safe verbatim and is also the
   *  part worth reading: a shape rejection is usually the scaffold's fault. */
  scaffold?: string;
  /** User-authored and short — a handler goal is a sentence, not a document. */
  goal?: string;
  /** Count only. The backlog is the user's own words to their agent. */
  backlogChars?: number;
  /** The transcript / PTY excerpt, identified without being read: the digest
   *  answers "was this the same context as the previous attempt", which is the
   *  question a retry raises, and it answers it with nothing to leak. */
  context?: { sha256: string; chars: number };
  /** The excerpt itself. Only when the separate context arm is up alongside the
   *  prompt one — see `armContextCapture`, which exists because this field is
   *  the dangerous one. */
  contextText?: string;
}

export interface ModelCallEvent {
  /** Monotonic counter of this process. Gaps across a capture mean events were
   *  evicted faster than the reader drained them. */
  seq: number;
  at: number;
  /** Joins one call's attempts to the outcome the caller recorded for it. Minted
   *  at the caller — everything is in one process, so it can be random rather
   *  than content-derived the way netwatch's cross-endpoint frameId must be. */
  callId: string;
  phase: ModelCallPhase;
  purpose: ModelCallPurpose;
  /** 1-based. A judge retry is attempt 2, and recording per attempt rather than
   *  per call is what makes a retry starved of its shared budget visible. */
  attempt: number;

  /** The agent the session runs. */
  requestedTool: string;
  /** What actually ran. The two differ on a borrow, which bills a vendor the
   *  user did not pick for this session. */
  actualTool: string;
  /** Which headless entry served the call. Widened to `string` deliberately: the
   *  recorder is imported by the spawn path itself, and it must not take an
   *  import back into the agents layer to name three literals. */
  reach: string;
  /** What we asked for. Absent means no `--model` was passed at all, so the call
   *  ran on whatever the vendor's CLI defaults to on this machine. */
  requestedModel?: string;
  /** What the vendor says ran. Differs from `requestedModel` when a scratch home
   *  drops the user's model selection. */
  actualModel?: string;

  terminalId?: string;
  conversationId?: string;
  projectId?: string;

  wallMs?: number;
  /** Vendor-reported model time, which separates the API call from process
   *  startup — the two together are what a timeout budget is actually spent on,
   *  and today the budget is a stated guess because nothing separates them. */
  apiMs?: number;
  exitCode?: number | null;
  timedOut?: boolean;
  budgetMs?: number;
  /** What this attempt left for the next one. A retry handed a few hundred
   *  milliseconds of a shared budget is structurally dead, and nothing else on
   *  the machine would ever say so. */
  remainingMs?: number;

  /** Vendor-tagged and never summed: the three CLIs report dollars, nothing, and
   *  fractional premium requests, so tokens and duration are the only
   *  denominators all of them share. */
  usage?: {
    inputTokens?: number;
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
    outputTokens?: number;
    /** Tokens the model spent thinking. Whether they are ALSO counted in
     *  `outputTokens` is the vendor's choice and differs between them —
     *  claude reports thinking as a breakdown of its output, codex and
     *  opencode as a sibling of theirs — so the two are never added together.
     *  Each reader states which it is at the path it reads. */
    reasoningTokens?: number;
    money?: { unit: string; amount: number };
    numTurns?: number;
    permissionDenials?: number;
    /** How many models the vendor billed for this ONE call, when it billed more
     *  than one. Present because the counts above are then their SUM while
     *  `actualModel` can name only one of them: a measured claude call reported
     *  901 input tokens of which the named model spent 2, the rest going to a
     *  background model the caller never asked for. Absent means one model, or
     *  a vendor that does not break its usage down by model at all. */
    modelsBilled?: number;
  };

  outcome?: string;
  /** The shape-rejection reason, the parse error — the half of a failed call
   *  that today is either logged once or discarded outright. */
  outcomeDetail?: string;

  promptChars?: number;
  stdoutChars?: number;
  /** Present only while the arms that admit them are up. Both are truncated and
   *  copied at the RECORD site (`capturePrompt`, `captureStdout`), never at
   *  render: the cap bounds what the ring HOLDS, and text admitted now is memory
   *  no later formatting decision can give back. Both are also dropped again
   *  when an arm lapses — see `Modelwatch.forgetCapturedText`. */
  prompt?: ModelCallPrompt;
  stdout?: string;
}

/**
 * What a CALLER hands the spawn so its records can be attributed — everything
 * the spawn cannot know on its own, which is everything about why it is running.
 *
 * A caller that supplies none is not recorded. That keeps the parameter additive
 * rather than a second thing every existing call site has to get right.
 */
export interface ModelCallContext {
  callId: string;
  purpose: ModelCallPurpose;
  attempt: number;
  requestedTool: string;
  actualTool: string;
  reach: string;
  requestedModel?: string;
  terminalId?: string;
  conversationId?: string;
  projectId?: string;
  budgetMs?: number;
  promptChars?: number;
  /** Already through `capturePrompt` when it arrives here. The raw parts never
   *  cross this boundary, so a caller cannot hand the recorder a prompt the arms
   *  did not sanction. */
  prompt?: ModelCallPrompt;
}

/**
 * Sized against Netwatch's 16384, and smaller on purpose. That ring watches a
 * loopback socket carrying a desktop's whole terminal output, where a scrolling
 * build evicts thousands of events within seconds, so it has to be large just to
 * hold the minute before a failure. Model calls arrive a few hundred times a day
 * on a busy machine, and the one worth inspecting happened minutes or hours ago
 * — so a ring an eighth the size holds days of history rather than seconds of it.
 */
const DEFAULT_CAPACITY = 2048;

/**
 * Per-machine override, because the right window is a property of the workload.
 * Anything unparseable, fractional, zero or negative falls back rather than
 * being honoured: the capacity is the modulus of every ring index, so a bad one
 * does not fail loudly, it produces a ring that silently records nothing.
 *
 * The ceiling guards the one bad value that WOULD fail loudly, in the worst
 * place. `new Array(n)` throws RangeError past 2^32-1, the ring is constructed
 * at module scope, and this module is imported by the headless spawn path that
 * every model call goes through — so a fat-fingered env var would abort the
 * bridge at import, with an error naming an array length rather than the
 * variable that caused it. An observer must never be why the machine will not
 * start, and must never be why a model call cannot be made.
 */
const MAX_CAPACITY = 1_048_576;

function resolveCapacity(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_CAPACITY;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) return DEFAULT_CAPACITY;
  return Math.min(n, MAX_CAPACITY);
}

/**
 * The cap on every free-text field the ring will hold. A decision prompt's
 * context runs to twelve thousand characters and a chatty agent's stdout has no
 * bound at all, against a ring that keeps thousands of calls.
 */
export const MODELWATCH_TEXT_MAX_CHARS = 4096;

let promptCaptureEnabled = false;
let promptCaptureTimer: (ReturnType<typeof setTimeout> & { unref?: () => void }) | null = null;

let contextCaptureEnabled = false;
let contextCaptureTimer: (ReturnType<typeof setTimeout> & { unref?: () => void }) | null = null;

/**
 * Arm or disarm capture of the prompt parts we authored — scaffold and goal
 * verbatim, backlog as a count, context as a digest — for at most `ttlMs`.
 *
 * Metadata is always recorded; prompt parts never are unless someone explicitly
 * asked, so a recorder nobody is reading costs a token count and a duration and
 * nothing the user typed. The TTL is a dead man's switch rather than a policy:
 * the only thing that ever disarms is the watcher that armed it, and a watcher
 * killed with SIGKILL sends no disarm — without the lapse, one attach would
 * leave the host recording prompt text for the rest of its life with nothing on
 * the machine able to turn it off. Re-arming restarts the window; a disarm is
 * idempotent.
 *
 * This says nothing about the context arm. The two are independent because the
 * text they admit is not comparable.
 */
export function armPromptCapture(enabled: boolean, ttlMs: number): void {
  if (promptCaptureTimer) clearTimeout(promptCaptureTimer);
  promptCaptureTimer = null;
  // An arm with no expiry is the one request this refuses, for the reason above.
  if (!enabled || !Number.isFinite(ttlMs) || ttlMs <= 0) {
    promptCaptureEnabled = false;
    forgetTextNoArmStillAdmits();
    return;
  }
  promptCaptureEnabled = true;
  promptCaptureTimer = setTimeout(() => {
    promptCaptureEnabled = false;
    promptCaptureTimer = null;
    forgetTextNoArmStillAdmits();
  }, ttlMs) as ReturnType<typeof setTimeout> & { unref?: () => void };
  // An observer must never be the reason the bridge outlives its work.
  promptCaptureTimer.unref?.();
}

export function isPromptCaptureArmed(): boolean {
  return promptCaptureEnabled;
}

/**
 * Arm or disarm capture of the CONTEXT TEXT for at most `ttlMs` — the transcript
 * and PTY excerpt a decision prompt is built around.
 *
 * Separate from the prompt arm, and separate on purpose. That excerpt is not
 * ours: it is whatever the user typed and whatever the agent read back at them,
 * so it can hold a pasted key, the contents of an `.env` the agent opened, or a
 * password entered at a PTY prompt. There is no list of types that would make it
 * safe the way `BODY_REDACTED_MESSAGE_TYPES` makes a frame body safe, so the
 * only honest control is a second, explicit, shorter-lived decision.
 *
 * Arming this implies nothing about the prompt arm: both `contextText` and the
 * model's `stdout` — which the decide prompt requires to quote that excerpt back
 * verbatim — are recorded only when BOTH arms are up, so turning this on alone
 * still records no text.
 *
 * Same dead man's switch as `armPromptCapture`, and the lapse takes the text
 * already in the ring with it (`forgetTextNoArmStillAdmits`).
 */
export function armContextCapture(enabled: boolean, ttlMs: number): void {
  if (contextCaptureTimer) clearTimeout(contextCaptureTimer);
  contextCaptureTimer = null;
  if (!enabled || !Number.isFinite(ttlMs) || ttlMs <= 0) {
    contextCaptureEnabled = false;
    forgetTextNoArmStillAdmits();
    return;
  }
  contextCaptureEnabled = true;
  contextCaptureTimer = setTimeout(() => {
    contextCaptureEnabled = false;
    contextCaptureTimer = null;
    forgetTextNoArmStillAdmits();
  }, ttlMs) as ReturnType<typeof setTimeout> & { unref?: () => void };
  contextCaptureTimer.unref?.();
}

export function isContextCaptureArmed(): boolean {
  return contextCaptureEnabled;
}

/** What every field carrying the session's own words requires. Named once
 *  because two record sites and the purge below must all agree on it. */
function sessionTextArmed(): boolean {
  return promptCaptureEnabled && contextCaptureEnabled;
}

/**
 * Run on every disarm and every lapse, because a dead man's switch that bounds
 * only what is ADMITTED bounds nothing about what is RETAINED.
 *
 * Netwatch omits this and is right to: its ring holds seconds of a loopback
 * socket carrying a desktop's whole terminal output, so a captured body is
 * evicted almost as soon as the arm behind it lapses. This ring is sized the
 * other way ON PURPOSE — a few hundred model calls a day against `capacity`
 * slots is days of history — so without a purge, an excerpt admitted during a
 * sixty-second window stays readable a week later with both arms reporting
 * false, and the reader served it need never have armed anything.
 */
function forgetTextNoArmStillAdmits(): void {
  modelwatch.forgetCapturedText({
    promptParts: promptCaptureEnabled,
    sessionText: sessionTextArmed(),
  });
}

function truncationMarker(dropped: number): string {
  return `…[+${dropped} chars]`;
}

/**
 * A copy of `s` that shares no storage with the string it came from.
 *
 * A cap on characters is not a cap on bytes. JSC gives `String.prototype.slice`
 * a view onto its parent's buffer and `+` a rope over its fibers, so a capped
 * field cut out of a child process's stdout keeps the WHOLE of that stdout alive
 * for as long as the ring holds the event — measured here, four 4096-character
 * captures taken out of a large stdout retained 192 MB, against none for the
 * same loop keeping no slice. Netwatch can leave the same copy out because its
 * bodies are relay frames, bounded by the frame size; the strings arriving here
 * are an agent CLI's output and a transcript excerpt, and neither has a bound.
 *
 * utf16le round-trips every code unit, unpaired surrogates included, so the copy
 * is exact rather than merely close.
 */
function detached(s: string): string {
  return Buffer.from(s, "utf16le").toString("utf16le");
}

/**
 * The marker is counted INSIDE the cap, not appended past it: the cap is what
 * bounds the ring's memory, so text that announces its own truncation by growing
 * past the ceiling has defeated the thing it reports. Reserving against the
 * untruncated length can only over-reserve — the number finally printed is
 * smaller, so never longer — which is what keeps the count exact.
 */
function truncate(text: string): string {
  if (text.length <= MODELWATCH_TEXT_MAX_CHARS) return detached(text);
  const keep = MODELWATCH_TEXT_MAX_CHARS - truncationMarker(text.length).length;
  return detached(text.slice(0, keep) + truncationMarker(text.length - keep));
}

/**
 * The prompt a tap should record for these parts, or `undefined` while the
 * prompt arm is down — the caller passes the answer straight into the event, so
 * the disarmed one has to be the absent field rather than an empty object.
 *
 * The parts arrive separately and are never rejoined here, because the built
 * string is exactly the artifact no policy can be written about. `context` is
 * always reduced to a digest and a length; the text is admitted only under the
 * second arm.
 */
export function capturePrompt(parts: {
  scaffold?: string;
  goal?: string;
  backlogText?: string;
  context?: string;
}): ModelCallPrompt | undefined {
  if (!promptCaptureEnabled) return undefined;
  try {
    const out: ModelCallPrompt = {};
    if (parts.scaffold !== undefined) out.scaffold = truncate(parts.scaffold);
    if (parts.goal !== undefined) out.goal = truncate(parts.goal);
    if (parts.backlogText !== undefined) out.backlogChars = parts.backlogText.length;
    if (parts.context !== undefined) {
      out.context = {
        sha256: createHash("sha256").update(parts.context).digest("hex"),
        chars: parts.context.length,
      };
      if (sessionTextArmed()) out.contextText = truncate(parts.context);
    }
    return out;
  } catch {
    // These two helpers are the only recorder calls a tap makes OUTSIDE its own
    // guard: they run while the caller is still building runHeadless's argument,
    // so they sit outside both `noteCall` and runHeadless's try. A throw here
    // would reject the caller's promise, and HandlerEngine reads that as the
    // provider being down — parking a session over a judge that would have
    // answered. Losing the capture is the right side of that trade.
    return undefined;
  }
}

/**
 * The model's answer, or `undefined` unless BOTH arms are up.
 *
 * An answer is only as safe as the context it was given, and for the decide
 * prompt that is not a hazard but a certainty: `buildDecidePrompt` requires
 * every transition to `done`, `skipped` or `failed` to carry "a short verbatim
 * quote copied character-for-character out of the RECENT CONTEXT block", and the
 * harness discards a paraphrase. So an obedient judge answers with the excerpt
 * inside it, and admitting stdout under the prompt arm alone would put the
 * transcript into the ring THROUGH THE MODEL — past the arm whose entire purpose
 * is to withhold it. It rides `contextText`'s gate for that reason.
 */
export function captureStdout(text: string): string | undefined {
  if (!sessionTextArmed()) return undefined;
  try {
    return truncate(text);
  } catch {
    // Same reason as capturePrompt's: built into the event by the tap, ahead of
    // the guard that would have contained it.
    return undefined;
  }
}

export type ModelwatchSubscriber = (event: ModelCallEvent) => void;

/**
 * Bounded in-memory record of every headless model call this machine spawns on
 * the user's own provider accounts.
 *
 * Always recording, deliberately: a call worth inspecting — the judge that
 * timed out, the title that named itself after an error message — has already
 * happened by the time anyone asks, so a buffer that only fills once armed is a
 * buffer that is empty exactly when it matters. The cost is one small object per
 * attempt, against a process spawn.
 */
export class Modelwatch {
  private readonly ring: (ModelCallEvent | undefined)[];
  private write = 0;
  private count = 0;
  private seq = 0;
  private readonly subscribers = new Set<ModelwatchSubscriber>();

  constructor(
    private readonly capacity: number = resolveCapacity(process.env.ANTGRID_MODELWATCH_CAPACITY),
  ) {
    this.ring = new Array<ModelCallEvent | undefined>(capacity);
  }

  record(event: Omit<ModelCallEvent, "seq" | "at"> & { at?: number }): void {
    this.push({ ...event, seq: ++this.seq, at: event.at ?? Date.now() });
  }

  private push(full: ModelCallEvent): void {
    this.ring[this.write] = full;
    this.write = (this.write + 1) % this.capacity;
    if (this.count < this.capacity) this.count++;
    for (const fn of this.subscribers) {
      try {
        fn(full);
      } catch {
        // A watcher is an observer. It must never be able to fail a model call.
      }
    }
  }

  /**
   * Drop from events ALREADY recorded every text field the given arms would no
   * longer admit, leaving their metadata intact.
   *
   * `sessionText` covers the two fields that carry the user's own words —
   * `prompt.contextText` and `stdout`, which the decide prompt makes a copy of
   * it — and `promptParts` the rest of the prompt. Passing the arms in rather
   * than reading them keeps the admission rule stated in one place
   * (`forgetTextNoArmStillAdmits`), where the record sites read it too.
   *
   * Events are REPLACED rather than edited in place: the object in a slot is the
   * same one already handed to every subscriber, and a watcher's copy going
   * hollow underneath it would be the observer changing what it observed.
   */
  forgetCapturedText(arms: { promptParts: boolean; sessionText: boolean }): void {
    for (let i = 0; i < this.ring.length; i++) {
      const e = this.ring[i];
      if (!e) continue;
      const dropParts = !arms.promptParts && e.prompt !== undefined;
      const dropContext = !arms.sessionText && e.prompt?.contextText !== undefined;
      const dropStdout = !arms.sessionText && e.stdout !== undefined;
      if (!dropParts && !dropContext && !dropStdout) continue;
      const next: ModelCallEvent = { ...e };
      if (dropParts) delete next.prompt;
      else if (dropContext) {
        const { contextText: _withheld, ...kept } = next.prompt!;
        next.prompt = kept;
      }
      if (dropStdout) delete next.stdout;
      this.ring[i] = next;
    }
  }

  /** Events currently in the ring — the ceiling on what a replay can return. */
  get buffered(): number {
    return this.count;
  }

  /** Buffered events, oldest first. */
  snapshot(limit = this.capacity): ModelCallEvent[] {
    const take = Math.min(limit, this.count);
    const out: ModelCallEvent[] = [];
    const start = (this.write - take + this.capacity * 2) % this.capacity;
    for (let i = 0; i < take; i++) {
      const e = this.ring[(start + i) % this.capacity];
      if (e) out.push(e);
    }
    return out;
  }

  subscribe(fn: ModelwatchSubscriber): () => void {
    this.subscribers.add(fn);
    return () => {
      this.subscribers.delete(fn);
    };
  }

  /** Events recorded, then evicted by the ring — a reader's blind spot. */
  get evicted(): number {
    return this.seq - this.count;
  }

  get recorded(): number {
    return this.seq;
  }
}

/**
 * Process-global, because the calls it watches all funnel through one function
 * that every caller reaches by import. Threading a recorder from the session
 * layer down through the spawn would buy nothing and be missed by the next
 * call site added.
 */
export const modelwatch = new Modelwatch();

/**
 * Test seam — the suite shares one module cache across every spec file, so an
 * arm left standing by one file would decide whether the next one's calls carry
 * prompt text, and the suite would pass or fail on file order.
 */
export function __resetModelwatchForTest(): void {
  armPromptCapture(false, 0);
  armContextCapture(false, 0);
  const w = modelwatch as unknown as {
    ring: (ModelCallEvent | undefined)[];
    write: number;
    count: number;
    seq: number;
    subscribers: Set<ModelwatchSubscriber>;
  };
  w.ring.fill(undefined);
  w.write = 0;
  w.count = 0;
  w.seq = 0;
  w.subscribers.clear();
}
