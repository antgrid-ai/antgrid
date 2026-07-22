import { createMessage } from "../../bridge/src/protocol";
import type { TestEnv } from "./harness";

/**
 * Send agent:prompt and resolve on the first agent:turn-start for the session.
 * The chat driver spawns asynchronously after session:start's (synchronous)
 * session:result, so an early prompt races the driver registration and answers
 * agent:error "chat session not started". Re-send on that transient until a turn
 * opens or the overall budget elapses.
 */
export async function promptUntilTurnStart(
  env: TestEnv,
  sessionId: string,
  text = "Reply with exactly the word PONG and nothing else.",
): Promise<{ sessionId: string; turnId: string }> {
  const deadline = Date.now() + 45_000;
  let lastErr = "";
  while (Date.now() < deadline) {
    env.app.sendEncrypted(createMessage("agent:prompt", {
      sessionId,
      requestId: `prompt-${Date.now()}`,
      text,
    }));
    const evt = await env.app
      .waitFor(
        (m: any) =>
          m.sessionId === sessionId &&
          (m.type === "agent:turn-start" || m.type === "agent:error"),
        8_000,
      )
      .catch(() => null);
    if (evt?.type === "agent:turn-start") return evt;
    if (evt?.type === "agent:error") {
      lastErr = evt.error?.message ?? "";
      // Only the warm-up race is retryable; a real driver error must surface.
      if (!/not started/i.test(lastErr)) {
        throw new Error(`agent:error before turn-start: ${lastErr}`);
      }
      await Bun.sleep(500);
    }
  }
  throw new Error(`no agent:turn-start within budget (last error: ${lastErr})`);
}
