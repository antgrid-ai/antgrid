import type { NotificationType, WorkStatus } from "./protocol";
import { isCtrlC, isLoneEsc, isSubmitKeystroke, opensCommandLine } from "./keystrokes";

// A level-triggered shadow of the work-status reduction. It reads the agent's
// terminal-title spinner plus a small block record and reports where that
// disagrees with the edge-triggered reducer in work-status.ts. Pure fold:
// no I/O, no clock, every transition takes `now`.

export type ShadowAgent = "claude-code" | "codex";
export type TitleClass = "spin" | "idle" | "blocked" | "other";
export type Coarse = "working" | "needs-you" | "idle";
export type ShadowKey = "esc" | "ctrl-c" | "submit" | "command-submit" | "slash" | "digit";

/** Codex can show a spinner-less title in the middle of a turn, so a single
 *  non-spinning frame must not read as the turn ending. */
export const TITLE_IDLE_DEBOUNCE_MS = 1_500;
/** The permission Notification lags its dialog by ~6 s, plus the time to spawn
 *  the hook; a disagreement shorter than that is the old reducer catching up. */
export const DISAGREEMENT_GRACE_MS = 15_000;
export const EVIDENCE_LIMIT = 12;
/** Bounds the lines one PTY run can write, so a wedged or flapping session
 *  cannot flood the host log. */
export const ONSET_LOG_CAP = 20;

export function shadowAgent(tool: string | undefined): ShadowAgent | undefined {
  return tool === "claude-code" || tool === "codex" ? tool : undefined;
}

export function shadowKey(data: string): ShadowKey | undefined {
  if (isLoneEsc(data)) return "esc";
  if (isCtrlC(data)) return "ctrl-c";
  if (isSubmitKeystroke(data)) return data.startsWith("/") ? "command-submit" : "submit";
  if (opensCommandLine(data)) return "slash";
  if (/^[1-9]$/.test(data)) return "digit";
  return undefined;
}

// Claude <= 2.1.227 spun braille glyphs; later builds spin the quarter circles.
const CLAUDE_SPIN = /^[◐-◓⠁-⣿]/u;
const CLAUDE_IDLE = /^✳ /u;
// While a thread title is being generated an idle title can read "⠋ | proj",
// so a glyph followed by the separator is not a spin. "● " is the microphone
// prefix and "[ . ]" is the blink frame of "[ ! ]".
const CODEX_SPIN = /^(?:● )?[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?:$| (?!\| ))/u;
const CODEX_BLOCK = /^(?:● )?\[ [!.] \] Action Required/u;

export function classifyTitle(agent: ShadowAgent, title: string): TitleClass {
  if (agent === "claude-code") {
    if (CLAUDE_SPIN.test(title)) return "spin";
    if (CLAUDE_IDLE.test(title)) return "idle";
    return "other";
  }
  if (CODEX_BLOCK.test(title)) return "blocked";
  if (CODEX_SPIN.test(title)) return "spin";
  // Codex clears the title when no segment is visible, so empty is idle.
  return "idle";
}

export type ShadowEvent =
  | { kind: "title"; title: string }
  | { kind: "notify"; type: NotificationType }
  | { kind: "ask-open" }
  | { kind: "ask-answered" }
  | { kind: "at-prompt" }
  | { kind: "turn-end" }
  | { kind: "key"; key: ShadowKey; via: "user" | "bus" };

type BlockSource = "notify" | "ask";

interface Evidence {
  readonly at: number;
  readonly what: string;
}

interface Span {
  readonly since: number;
  readonly first: string;
  readonly last: string;
  readonly pastGrace: boolean;
  readonly emitted: boolean;
}

export interface ShadowSession {
  readonly agent: ShadowAgent;
  readonly trackedAt: number;
  readonly observable: boolean;
  /** Dedups repeated frames, so it includes "other". */
  readonly lastClass?: TitleClass;
  /** What edges are judged against; an unrecognised title never writes it. */
  readonly lastKnown?: Exclude<TitleClass, "other">;
  readonly spinning: boolean;
  readonly workingUntil?: number;
  readonly block?: BlockSource;
  readonly lastOld?: WorkStatus;
  readonly span?: Span;
  readonly evidence: readonly Evidence[];
  readonly onsets: number;
  readonly suppressed: number;
}

export interface ShadowState {
  readonly sessions: ReadonlyMap<string, ShadowSession>;
}

export interface ShadowLine {
  msg: string;
  fields: Record<string, unknown>;
}

export const initialShadow: ShadowState = { sessions: new Map() };

const MSG_ONSET = "status shadow: disagreement";
const MSG_RESOLVED = "status shadow: agreed again";
const MSG_SUMMARY = "status shadow: disagreements past grace not logged";

function put(state: ShadowState, id: string, s: ShadowSession): ShadowState {
  const sessions = new Map(state.sessions);
  sessions.set(id, s);
  return { sessions };
}

function withEvidence(s: ShadowSession, now: number, what: string): ShadowSession {
  const evidence = [...s.evidence, { at: now, what }];
  if (evidence.length > EVIDENCE_LIMIT) evidence.splice(0, evidence.length - EVIDENCE_LIMIT);
  return { ...s, evidence };
}

function formatEvidence(s: ShadowSession, now: number): string[] {
  return s.evidence.map((e) => `-${now - e.at}ms ${e.what}`);
}

export function track(prev: ShadowState, id: string, agent: ShadowAgent, now: number): ShadowState {
  return put(prev, id, {
    agent,
    trackedAt: now,
    observable: false,
    spinning: false,
    evidence: [],
    onsets: 0,
    suppressed: 0,
  });
}

function retire(s: ShadowSession): ShadowSession {
  if (!s.block) return s;
  const { block: _gone, ...rest } = s;
  return rest;
}

function retireUnlessAsk(s: ShadowSession): ShadowSession {
  return s.block && s.block !== "ask" ? retire(s) : s;
}

function open(s: ShadowSession, source: BlockSource): ShadowSession {
  return s.block ? s : { ...s, block: source };
}

function codexTitleBlocked(s: ShadowSession): boolean {
  return s.agent === "codex" && s.lastKnown === "blocked";
}

function observeTitle(s: ShadowSession, title: string, now: number): ShadowSession {
  const cls = classifyTitle(s.agent, title);
  if (cls === s.lastClass) return s;
  if (!s.observable && cls !== "spin" && !(s.agent === "codex" && cls === "blocked")) return s;
  let next: ShadowSession = s.observable ? s : { ...s, observable: true };

  if (cls === "other") {
    // Claude always writes an explicit idle glyph when it stops, and on Windows
    // ConPTY can forward a child's console title, so an unknown title carries
    // no state: the spinner frame after it is not a new spin edge.
    const cp = (title.codePointAt(0) ?? 0).toString(16);
    return withEvidence({ ...next, lastClass: cls }, now, `title:other:${cp}`);
  }
  if (cls === "spin") {
    const { workingUntil: _w, ...rest } = next;
    next = { ...rest, spinning: true };
    if (s.lastKnown !== "spin") next = retire(next);
  } else if (cls === "idle") {
    if (next.spinning) next = { ...next, spinning: false, workingUntil: now + TITLE_IDLE_DEBOUNCE_MS };
    // Codex's title is the authority for its own approval and question views,
    // including deny and request_user_input paths that fire no hook.
    if (codexTitleBlocked(s)) next = retire(next);
  } else {
    const { workingUntil: _w, ...rest } = next;
    next = { ...rest, spinning: false };
  }
  return withEvidence({ ...next, lastClass: cls, lastKnown: cls }, now, `title:${cls}`);
}

function observeOther(s: ShadowSession, ev: Exclude<ShadowEvent, { kind: "title" }>, now: number): ShadowSession {
  switch (ev.kind) {
    case "notify": {
      let next = s;
      if (ev.type === "permission_request" || ev.type === "question") next = open(s, "notify");
      else if (ev.type === "task_complete" || ev.type === "idle" || ev.type === "error") next = retire(s);
      // A forwarded idle nudge means the old reducer still holds a block, so it
      // retires nothing here; an absorbed one arrives as at-prompt.
      return withEvidence(next, now, `notify:${ev.type}`);
    }
    case "at-prompt":
      return withEvidence(retire(s), now, "at-prompt");
    case "ask-open":
      return withEvidence({ ...s, block: "ask" }, now, "ask:open");
    case "ask-answered":
      return withEvidence(retire(s), now, "ask:answered");
    case "turn-end":
      return withEvidence(retire(s), now, "turn-end");
    case "key": {
      const what = `${ev.via === "bus" ? "bus" : "key"}:${ev.key}`;
      switch (ev.key) {
        case "esc":
        case "ctrl-c":
          return withEvidence(retire(s), now, what);
        // Enter moves between the questions of a multi-question ask, so only
        // prompt_answered retires an ask block.
        case "submit":
        case "command-submit":
        case "digit":
          return withEvidence(retireUnlessAsk(s), now, what);
        case "slash":
          return withEvidence(s, now, what);
      }
    }
  }
}

export function observe(prev: ShadowState, id: string, ev: ShadowEvent, now: number): ShadowState {
  const s = prev.sessions.get(id);
  if (!s) return prev;
  const next = ev.kind === "title" ? observeTitle(s, ev.title, now) : observeOther(s, ev, now);
  return next === s ? prev : put(prev, id, next);
}

export function coarseOld(s: WorkStatus | undefined): Coarse | undefined {
  switch (s) {
    case "working": return "working";
    case "attention": return "needs-you";
    case "done":
    case "unread":
    case "error": return "idle";
    default: return undefined;
  }
}

export function shadowClass(s: ShadowSession, now: number): Coarse | undefined {
  if (!s.observable) return undefined;
  if (s.spinning || (s.workingUntil !== undefined && now < s.workingUntil)) return "working";
  // The Action Required title is level-triggered and outranks the block record:
  // Enter, a digit or Esc can move between the questions of a request_user_input
  // view, or clear a draft, while the view stays open.
  return s.block || codexTitleBlocked(s) ? "needs-you" : "idle";
}

export function compare(
  prev: ShadowState,
  id: string,
  old: WorkStatus | undefined,
  now: number,
): { state: ShadowState; lines: ShadowLine[] } {
  const orig = prev.sessions.get(id);
  if (!orig) return { state: prev, lines: [] };
  const lines: ShadowLine[] = [];
  let s = orig;

  if (s.workingUntil !== undefined && now >= s.workingUntil) {
    const { workingUntil: _w, ...rest } = s;
    s = rest;
  }
  if (old !== s.lastOld) {
    s = withEvidence({ ...s, lastOld: old }, now, `old:${old ?? "none"}`);
  }

  const o = coarseOld(old);
  const sh = shadowClass(s, now);

  if (o !== undefined && sh !== undefined && o !== sh) {
    const pair = `${o}/${sh}`;
    let span: Span = s.span ?? { since: now, first: pair, last: pair, pastGrace: false, emitted: false };
    if (span.last !== pair) span = { ...span, last: pair };
    if (!span.pastGrace && now - span.since >= DISAGREEMENT_GRACE_MS) {
      span = { ...span, pastGrace: true };
      if (s.onsets < ONSET_LOG_CAP) {
        const onsets = s.onsets + 1;
        span = { ...span, emitted: true };
        s = { ...s, onsets };
        lines.push({
          msg: MSG_ONSET,
          fields: {
            terminalId: id,
            agent: s.agent,
            old,
            oldClass: o,
            shadow: sh,
            first: span.first,
            forMs: now - span.since,
            sinceTrackMs: now - s.trackedAt,
            evidence: formatEvidence(s, now),
            ...(onsets === ONSET_LOG_CAP ? { capped: true } : {}),
          },
        });
      } else {
        s = { ...s, suppressed: s.suppressed + 1 };
      }
    }
    if (span !== s.span) s = { ...s, span };
  } else if (s.span) {
    if (s.span.emitted) {
      lines.push({
        msg: MSG_RESOLVED,
        fields: {
          terminalId: id,
          agent: s.agent,
          durationMs: now - s.span.since,
          last: s.span.last,
          to: o !== undefined && sh !== undefined ? sh : "unobservable",
          evidence: formatEvidence(s, now),
        },
      });
    }
    const { span: _gone, ...rest } = s;
    s = rest;
  }

  return { state: s === orig ? prev : put(prev, id, s), lines };
}

export function exited(prev: ShadowState, id: string, now: number): { state: ShadowState; lines: ShadowLine[] } {
  const s = prev.sessions.get(id);
  if (!s) return { state: prev, lines: [] };
  const lines: ShadowLine[] = [];
  if (s.span?.emitted) {
    lines.push({
      msg: MSG_RESOLVED,
      fields: {
        terminalId: id,
        agent: s.agent,
        durationMs: now - s.span.since,
        last: s.span.last,
        to: "exit",
        evidence: formatEvidence(s, now),
      },
    });
  }
  if (s.suppressed > 0) {
    lines.push({ msg: MSG_SUMMARY, fields: { terminalId: id, agent: s.agent, suppressed: s.suppressed } });
  }
  const sessions = new Map(prev.sessions);
  sessions.delete(id);
  return { state: { sessions }, lines };
}

export function nextDeadline(state: ShadowState): number | undefined {
  let min: number | undefined;
  for (const s of state.sessions.values()) {
    if (s.workingUntil !== undefined && (min === undefined || s.workingUntil < min)) min = s.workingUntil;
    if (s.span && !s.span.pastGrace) {
      const d = s.span.since + DISAGREEMENT_GRACE_MS;
      if (min === undefined || d < min) min = d;
    }
  }
  return min;
}
