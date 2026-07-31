// bridge/src/handler/lifecycle-classify.ts
import type { AgentError } from "../protocol";
import type { HandlerEvent } from "./engine";

export type LifecycleClassification = Pick<HandlerEvent, "resetsAt" | "errorClass"> & {
  event: Extract<HandlerEvent["event"], "limit_hit" | "turn_failed">;
};

/**
 * Map a normalized turn-end error onto a lifecycle event, or null when the
 * failure is not one a wait can fix (auth, context overflow, a user abort) —
 * those keep the plain `turn_end` path so the judge still sees them.
 *
 * Pure: `now` is passed in so the caller owns the clock.
 */
export function classifyTurnEndError(error: AgentError, now: number): LifecycleClassification | null {
  switch (error.category) {
    case "rate_limited":
    case "quota_exceeded":
      return {
        event: "limit_hit",
        errorClass: error.category,
        ...(typeof error.retryAfterMs === "number"
          ? { resetsAt: now + error.retryAfterMs }
          : {}),
      };
    case "server_error":
    case "network":
      // No resetsAt: an outage has no announced end, so the engine's backoff
      // series decides the wait rather than a provider hint about a limit.
      return { event: "turn_failed", errorClass: error.category };
    default:
      return null;
  }
}
