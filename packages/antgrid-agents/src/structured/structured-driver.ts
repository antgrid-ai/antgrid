import type { AbMessage } from "../protocol";
import type { CapCommand } from "./chat-session";

// Structural type the manager needs from a driver (CodexDriver satisfies it).
export interface StructuredDriver {
  // Resolves with the backend-native session id, or "" when the backend only
  // reports its id asynchronously (e.g. ClaudeDriver: the SDK emits it on
  // system:init, after start() must already have returned — see agents/claude-code/chat-backend.ts).
  // In the "" case the factory wires persistence out-of-band (an onSessionId
  // callback), and the manager must skip persistence for falsy ids — see the
  // `if (agentId)` guard in startChat.
  start(resumeId?: string, signal?: AbortSignal): Promise<string>;
  // commandId present => slash-command invocation; text carries only the args.
  prompt(text: string, commandId?: string): Promise<void>;
  // Returns whether a live turn was actually interrupted. False means there was
  // nothing to cancel, and the manager answers the client itself — see the
  // agent:cancel case in handleAgentMessage.
  cancel(turnId?: string): Promise<boolean>;
  compact?(): Promise<void>;
  revert?(target: { turnId?: string; itemId?: string; messageId?: string; partId?: string }): Promise<void>;
  // Store a session-scoped selection (model/effort/mode); applied on the next
  // turn. Unknown keys/ids are ignored (no error round-trip — the absent
  // capabilities echo is the signal).
  setConfig(key: string, value: unknown): void;
  // Re-derive this session's completed-turn transcript from the live backend on
  // demand (no restart). Optional: only chat-capable drivers implement it.
  // Returns [] when there's nothing to backfill, or a turn is actively
  // streaming and can't be safely partial-included.
  getTranscriptSnapshot?(): Promise<AbMessage[]>;
  resolvePermission(permissionId: string, optionId: string): void;
  resolveQuestion(questionId: string, answer: string | string[]): void;
  // Stop one background task (agent:task-stop). Optional for the same reason as
  // getTranscriptSnapshot above: presence IS the capability, so there is no
  // second list to keep in lockstep. The verb is unreachable for a driver that
  // implements nothing — the app only offers a stop for a task the session
  // itself advertised — so the no-op is an invariant, not a silent default.
  stopTask?(taskId: string): Promise<void>;
  // This session's slash commands, or undefined when there is no catalog to
  // offer. Optional for the same reason as stopTask: presence IS the
  // capability, so there is no second list to keep in lockstep.
  commandCatalog?(): CapCommand[] | undefined;
  // May be async: a driver whose backend holds a process-global lock (codex's
  // ~/.codex sqlite) resolves only once that process has fully exited, so a
  // restart doesn't race the dying one for the lock.
  dispose(): void | Promise<void>;
}

export interface DriverRunContext {
  signal: AbortSignal;
  isCurrent: () => boolean;
  onAgentSession: (agentSessionId: string) => void;
}
