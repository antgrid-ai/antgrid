// Transport seam (spec §Session adapter seam): everything above this interface —
// Brief, judge, ledger, floors, runaway guard — is transport-agnostic. The PTY
// adapter writes to a live terminal; the structured (chat) adapter lives in
// structured-adapter.ts and rides the driver's prompt path.
export interface SessionAdapter {
  injectReply(sessionId: string, text: string): void;
  // Promise for chat sessions (context is rendered from an async driver
  // snapshot); plain string for PTY. The engine awaits either.
  recentOutput(sessionId: string): string | Promise<string>;
  // What recentOutput returns: raw PTY scrollback (noisy — gets a tighter
  // context cap) vs. a rendered transcript snapshot (already structured, so it
  // earns the full per-purpose budget). See assembleContext's recentKind.
  outputKind(sessionId: string): "pty" | "rendered";
  transcriptPath(sessionId: string): string | undefined;
  // Slash commands are typed text in a PTY; structured drivers need a commandId
  // the judge doesn't have, so chat adapters refuse and the engine escalates.
  supportsSlashCommands(sessionId: string): boolean;
}

export function createPtyAdapter(deps: {
  write: (terminalId: string, data: string) => void;
  getRecentOutput: (terminalId: string) => string;
  getTranscriptPath: (terminalId: string) => string | undefined;
}): SessionAdapter {
  return {
    // The trailing CR submits the line; the engine has already floor/cap-checked
    // the text (which is why control chars in `text` itself are rejected there).
    injectReply: (id, text) => deps.write(id, `${text}\r`),
    recentOutput: (id) => deps.getRecentOutput(id),
    outputKind: () => "pty",
    transcriptPath: (id) => deps.getTranscriptPath(id),
    supportsSlashCommands: () => true,
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
    injectReply: (id, text) => pick(id).injectReply(id, text),
    recentOutput: (id) => pick(id).recentOutput(id),
    outputKind: (id) => pick(id).outputKind(id),
    transcriptPath: (id) => pick(id).transcriptPath(id),
    supportsSlashCommands: (id) => pick(id).supportsSlashCommands(id),
  };
}
