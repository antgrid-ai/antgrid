import type { CapCommand } from "../structured/chat-session";

// Transport seam (spec §Session adapter seam): everything above this interface —
// goal + backlog, judge, floors, runaway guard — is transport-agnostic. The PTY
// adapter writes to a live terminal; the structured (chat) adapter lives in
// structured-adapter.ts and rides the driver's prompt path.

/** A catalog hit the engine already resolved: the chat transport routes on
 *  `id` and sends `args` as its text, while a PTY ignores it — the verb is
 *  already inside `text` there, and a terminal has no routing channel. */
export interface InjectCommand { id: string; args: string }

export interface SessionAdapter {
  injectReply(sessionId: string, text: string, command?: InjectCommand): void;
  // Promise for chat sessions (context is rendered from an async driver
  // snapshot); plain string for PTY. The engine awaits either.
  recentOutput(sessionId: string): string | Promise<string>;
  // What recentOutput returns: raw PTY scrollback (noisy — gets a tighter
  // context cap) vs. a rendered transcript snapshot (already structured, so it
  // earns the full per-purpose budget). See assembleContext's recentKind.
  outputKind(sessionId: string): "pty" | "rendered";
  transcriptPath(sessionId: string): string | undefined;
  // Non-empty or nothing: undefined means "no catalog available for this
  // session", which a PTY always answers and a chat session answers until its
  // driver reports one. The engine requires membership only when a catalog IS
  // available — an invented verb typed at a terminal is visible and
  // recoverable, an invented allowlist verdict is not.
  commandCatalog(sessionId: string): CapCommand[] | undefined;
}

export function createPtyAdapter(deps: {
  submit: (terminalId: string, line: string) => void;
  getRecentOutput: (terminalId: string) => string;
  getTranscriptPath: (terminalId: string) => string | undefined;
}): SessionAdapter {
  return {
    // The seam hands over the line and the terminal layer submits it as a
    // separate write: a CR sharing a read with 64+ characters of text is
    // absorbed into it and inserted as literal text (see pty-submit.ts). The
    // engine has already floor/cap-checked the text, which is why control chars
    // in `text` itself are rejected there.
    injectReply: (id, text) => deps.submit(id, text),
    recentOutput: (id) => deps.getRecentOutput(id),
    outputKind: () => "pty",
    transcriptPath: (id) => deps.getTranscriptPath(id),
    commandCatalog: () => undefined,
  };
}

// One engine, two transports: sessions are keyed by opaque slot id, so route
// each call by the slot's live mode rather than fixing the transport at
// construction (a project mixes PTY and chat sessions freely).
export function createDispatchAdapter(deps: {
  isChat: (sessionId: string) => boolean;
  pty: SessionAdapter;
  chat: SessionAdapter;
}): SessionAdapter {
  const pick = (id: string) => (deps.isChat(id) ? deps.chat : deps.pty);
  return {
    injectReply: (id, text, command) => pick(id).injectReply(id, text, command),
    recentOutput: (id) => pick(id).recentOutput(id),
    outputKind: (id) => pick(id).outputKind(id),
    transcriptPath: (id) => pick(id).transcriptPath(id),
    commandCatalog: (id) => pick(id).commandCatalog(id),
  };
}
