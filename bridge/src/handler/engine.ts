// bridge/src/handler/engine.ts
import { createMessage, type AbMessage } from "../protocol";
import { TEMPLATES, type HandlerTemplate } from "./templates";
import { classifyDestructive } from "./destructive-floor";
import { RunawayGuard } from "./runaway-guard";
import { assembleContext } from "./context";
import { runJudge as defaultRunJudge } from "./judge";
import { loadHandlerConfig, saveHandlerConfig, appendActivity, type HandlerConfig, type ActivityRecord } from "./config";
import type { HandlerDecision } from "./decision";

export interface HandlerEngineDeps {
  projectId: string;
  projectPath: string;
  // A thunk, not a snapshot: the tool can be chosen after construction (the first-run
  // wizard sets config.agent.tool later), so resolve it lazily on each use.
  tool: () => string;
  abDir: string;
  write: (terminalId: string, data: string) => void;
  sendAb: (msg: AbMessage) => void;
  getRecentOutput: (terminalId: string) => string;
  runJudgeFn?: typeof defaultRunJudge;
  loadConfigFn?: () => HandlerConfig;
  saveConfigFn?: (cfg: HandlerConfig) => void;
  appendActivityFn?: (rec: ActivityRecord) => void;
  now?: () => number;
  guard?: RunawayGuard;
}

export class HandlerEngine {
  private guard: RunawayGuard;
  private state: "off" | "watching" | "handling" | "needs_you" = "off";
  // Outstanding escalations per terminal, so a reply on terminal A can't clear terminal B's.
  private pendingByTerminal = new Map<string, number>();
  private cachedConfig: HandlerConfig | null = null;
  private seq = 0;

  constructor(private deps: HandlerEngineDeps) {
    this.guard = deps.guard ?? new RunawayGuard();
  }

  // configure() is the only in-process writer, so cache the parsed config and never re-read
  // from disk on the event/status hot path (handleEvent + emitStatus fire per terminal event).
  private cfg(): HandlerConfig {
    if (this.cachedConfig) return this.cachedConfig;
    this.cachedConfig = this.deps.loadConfigFn
      ? this.deps.loadConfigFn()
      : loadHandlerConfig(this.deps.abDir, this.deps.projectId);
    return this.cachedConfig;
  }

  private totalPending(): number {
    let n = 0;
    for (const v of this.pendingByTerminal.values()) n += v;
    return n;
  }
  private now(): number { return this.deps.now ? this.deps.now() : Date.now(); }
  private id(prefix: string): string { return `${prefix}-${this.deps.projectId}-${this.now()}-${this.seq++}`; }

  currentState(): "off" | "watching" | "handling" | "needs_you" { return this.state; }

  configure(p: { enabled: boolean; template: HandlerTemplate; model?: string }): void {
    // Persist so handleEvent's cfg() (which reads the store) sees the app's choice and
    // it survives a bridge restart. Without this the engine re-reads the on-disk default
    // and ignores every event.
    const cfg: HandlerConfig = { version: 1, enabled: p.enabled, template: p.template, model: p.model };
    (this.deps.saveConfigFn ?? ((c: HandlerConfig) => saveHandlerConfig(this.deps.abDir, this.deps.projectId, c)))(cfg);
    this.cachedConfig = cfg;
    this.state = p.enabled ? "watching" : "off";
    this.emitStatus(cfg);
  }

  onUserReply(terminalId: string): void {
    this.guard.reset(terminalId);
    // Disabled handler: nothing to reflect. Avoids a synchronous config read + an
    // encrypted handler:status on every keystroke in the default-off state.
    if (this.state === "off") return;
    const prevTotal = this.totalPending();
    const prevState = this.state;
    const cur = this.pendingByTerminal.get(terminalId) ?? 0;
    if (cur > 1) this.pendingByTerminal.set(terminalId, cur - 1);
    else if (cur === 1) this.pendingByTerminal.delete(terminalId);
    // Stay needs_you while OTHER terminals still have unanswered escalations.
    this.state = this.totalPending() > 0 ? "needs_you" : "watching";
    if (this.state !== prevState || this.totalPending() !== prevTotal) this.emitStatus();
  }

  // A terminal that exits without a user reply would otherwise leak its guard + pending state.
  onTerminalExit(terminalId: string): void {
    this.guard.reset(terminalId);
    if (this.state === "off") return;
    if (this.pendingByTerminal.delete(terminalId)) {
      this.state = this.totalPending() > 0 ? "needs_you" : "watching";
      this.emitStatus();
    }
  }

  async handleEvent(evt: {
    terminalId: string; event: "turn_end" | "awaiting_input"; transcriptPath?: string; sessionId?: string;
  }): Promise<void> {
    const cfg = this.cfg();
    if (!cfg.enabled) return;

    const policy = TEMPLATES[cfg.template];
    this.state = "handling";
    this.emitStatus(cfg);

    // A rejection from assembleContext/runJudge (or any unexpected throw) must not
    // strand state in "handling" — reset to needs_you/watching before rethrowing so
    // the next event isn't ignored and the app's status pill reflects reality.
    try {
      // Watchdog (or any non-auto-reply template) escalates without spending a judge call.
      if (!policy.autoReplyAllowed) {
        this.escalate(evt.terminalId, {
          decision: "escalate", confidence: 0, reason: `${cfg.template}: escalating all events`,
          notify: { title: "Handler", body: "Agent needs you", draftReply: "", urgency: "normal" },
        });
        return;
      }

      const tool = this.deps.tool();
      const ctx = await assembleContext({
        tool, transcriptPath: evt.transcriptPath, recentPty: this.deps.getRecentOutput(evt.terminalId),
      });
      const runJudge = this.deps.runJudgeFn ?? defaultRunJudge;
      const decision = await runJudge({
        tool, model: cfg.model, guidance: policy.judgeGuidance, context: ctx.text, cwd: this.deps.projectPath,
      });

      if (!decision) {
        this.escalate(evt.terminalId, {
          decision: "escalate", confidence: 0, reason: "judge unavailable",
          notify: { title: "Handler", body: "Agent needs you (judge unavailable)", draftReply: "", urgency: "normal" },
        });
        return;
      }

      if (decision.decision === "handle") {
        const reply = (decision.reply ?? "").trim();
        const actionText = decision.action?.kind === "slash_command" ? decision.action.value : "";
        const probe = `${reply}\n${actionText}`;
        if (!reply && !actionText) return this.escalate(evt.terminalId, decision, "empty reply");

        // Harness guards on the gate-bypassing write channel (alongside the floor): a
        // compromised/hallucinating judge must not inject an unbounded blob or smuggle
        // multiple commands via embedded newlines/control chars in one "handle".
        const MAX_REPLY_CHARS = 4096;
        const written = actionText || reply;
        if (written.length > MAX_REPLY_CHARS) {
          return this.escalate(evt.terminalId, decision, `reply too long (${written.length} > ${MAX_REPLY_CHARS})`);
        }
        // C0 controls + DEL. We append our own "\r" when submitting; any control char in
        // the judge's text (esp. \n/\r) would submit multiple PTY lines from one decision.
        if (/[\x00-\x1f\x7f]/.test(written)) {
          return this.escalate(evt.terminalId, decision, "reply contains control characters");
        }

        const floor = classifyDestructive(probe, this.deps.projectPath);
        if (floor.blocked) return this.escalate(evt.terminalId, decision, `floor: ${floor.reason}`);

        const guardReason = this.guard.check(evt.terminalId, probe);
        if (guardReason) return this.escalate(evt.terminalId, decision, guardReason);

        const data = (actionText || reply) + "\r";
        this.deps.write(evt.terminalId, data);
        this.guard.recordAutoReply(evt.terminalId, probe);
        this.record(evt.terminalId, "handle", decision.reason, reply || actionText);
        this.state = "watching";
        this.emitStatus(cfg);
        return;
      }

      if (decision.decision === "continue") {
        this.record(evt.terminalId, "continue", decision.reason);
        this.state = "watching";
        this.emitStatus(cfg);
        return;
      }

      this.escalate(evt.terminalId, decision);
    } catch (err) {
      this.state = this.totalPending() > 0 ? "needs_you" : "watching";
      this.emitStatus(cfg);
      throw err;
    }
  }

  private escalate(terminalId: string, decision: HandlerDecision, forcedReason?: string): void {
    const reason = forcedReason ?? decision.reason;
    const escalationId = this.id("esc");
    this.deps.sendAb(createMessage("handler:escalation", {
      projectId: this.deps.projectId,
      escalationId,
      terminalId,
      question: decision.notify?.body ?? "Agent needs you",
      reasoning: reason,
      draftReply: decision.notify?.draftReply ?? decision.reply ?? "",
      urgency: decision.notify?.urgency ?? "normal",
    }));
    this.pendingByTerminal.set(terminalId, (this.pendingByTerminal.get(terminalId) ?? 0) + 1);
    this.record(terminalId, "escalate", reason, decision.notify?.draftReply ?? decision.reply);
    this.state = "needs_you";
    this.emitStatus();
  }

  private record(terminalId: string, decision: "continue" | "handle" | "escalate", reason: string, detail?: string): void {
    const rec: ActivityRecord = { recordId: this.id("rec"), at: this.now(), terminalId, decision, reason, detail };
    (this.deps.appendActivityFn ?? ((r) => appendActivity(this.deps.abDir, this.deps.projectId, r)))(rec);
    this.deps.sendAb(createMessage("handler:activity", {
      projectId: this.deps.projectId, recordId: rec.recordId, at: rec.at, terminalId, decision, reason, detail,
    }));
  }

  private emitStatus(cfg?: HandlerConfig): void {
    const c = cfg ?? this.cfg();
    this.deps.sendAb(createMessage("handler:status", {
      projectId: this.deps.projectId,
      enabled: c.enabled,
      template: c.template,
      model: c.model,
      state: this.state,
      pendingEscalations: this.totalPending(),
    }));
  }
}
