// bridge/src/handler/runaway-guard.ts

// Supervisor + agent with no human between them is a closed loop. Cap consecutive
// auto-replies and detect a repeated reply (same point exchanged again). Reset on
// a human reply (engine calls reset when the user answers an escalation) — an
// ANSWER, meaning a submitted line or the app-routed resolve that arrives as a
// bare CR, never a bare keystroke or a mouse report, since `reset` drops
// recentHashes along with the cap.

interface GuardState { consecutive: number; recentHashes: string[]; }

// 32-bit djb2: a collision would false-escalate (distinct replies look circular),
// which is the safe direction — no destructive action is taken on a false positive.
function hash(s: string): string {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
  return String(h);
}

export class RunawayGuard {
  private state = new Map<string, GuardState>();

  constructor(private maxConsecutive = 5, private repeatWindow = 4) {}

  private get(id: string): GuardState {
    let s = this.state.get(id);
    if (!s) { s = { consecutive: 0, recentHashes: [] }; this.state.set(id, s); }
    return s;
  }

  check(terminalId: string, replyText: string): string | null {
    const s = this.get(terminalId);
    if (s.consecutive >= this.maxConsecutive) {
      return `runaway cap reached (${this.maxConsecutive} consecutive auto-replies)`;
    }
    if (s.recentHashes.includes(hash(replyText))) {
      return "circular exchange (this reply was already sent)";
    }
    return null;
  }

  recordAutoReply(terminalId: string, replyText: string): void {
    const s = this.get(terminalId);
    s.consecutive += 1;
    s.recentHashes.push(hash(replyText));
    if (s.recentHashes.length > this.repeatWindow) s.recentHashes.shift();
  }

  reset(terminalId: string): void { this.state.delete(terminalId); }

  // A backlog item reaching `done` (the only transition applyTransitions reports
  // as progress) is evidence of non-looping: lift the consecutive cap but keep
  // recentHashes — resending an identical reply is circular regardless of
  // progress elsewhere.
  recordProgress(terminalId: string): void {
    const s = this.state.get(terminalId);
    if (s) s.consecutive = 0;
  }
}
