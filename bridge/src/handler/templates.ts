// bridge/src/handler/templates.ts
export interface TemplatePolicy {
  // Whether the supervisor may inject a reply at all. Watchdog = pure notify.
  // This is the prompt/policy dial; the destructive floor (destructive-floor.ts)
  // is a SEPARATE harness gate that no template can loosen.
  autoReplyAllowed: boolean;
  judgeGuidance: string;
}

export type HandlerTemplate = "watchdog" | "closer" | "autopilot";

export const TEMPLATES: Record<HandlerTemplate, TemplatePolicy> = {
  watchdog: {
    autoReplyAllowed: false,
    judgeGuidance: "Never answer for the user. Escalate every awaiting-input event.",
  },
  closer: {
    autoReplyAllowed: true,
    judgeGuidance: "Answer only when highly confident and the action is low-risk. If uncertain or the move is risky, escalate.",
  },
  autopilot: {
    autoReplyAllowed: true,
    judgeGuidance: "Answer aggressively to keep the agent moving. Escalate only hard blockers: ambiguous product decisions, repeated failures, or destructive/irreversible/secret-touching actions.",
  },
};
