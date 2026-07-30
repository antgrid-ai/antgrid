import { createMessage } from "../../bridge/src/protocol";
import type { RelayClient } from "./relay-client";

/**
 * Send agent:prompt on a project stream and resolve on the first
 * agent:turn-start for the session.
 *
 * Chat verbs are project-scoped: `agent:prompt` and the whole `session:*` family
 * are handled by agent-core, while the machine control plane dispatches only
 * host verbs (`project:*`, `phones:*`, `mobile-access:*`). An untagged send is
 * dropped with no error frame, so every verb here carries `streamId`.
 *
 * The chat driver spawns asynchronously after session:start's (synchronous)
 * session:result, so an early prompt races the driver registration and answers
 * agent:error "chat session not started". That rejection is the ONLY reason to
 * re-send. A bare timeout means the prompt was ACCEPTED and the turn is merely
 * slow (a cold codex/claude spawn routinely exceeds a short per-wait window);
 * re-prompting there bills a second model turn and leaves the session with a
 * duplicate user message. So the wait spans the whole remaining budget in one
 * call and only an explicit retryable error re-prompts.
 */
export async function promptUntilTurnStart(
  app: RelayClient,
  streamId: string,
  sessionId: string,
  text = "Reply with exactly the word PONG and nothing else.",
): Promise<{ sessionId: string; turnId: string }> {
  const deadline = Date.now() + 45_000;
  const sendPrompt = () =>
    app.sendOnStream(streamId, createMessage("agent:prompt", {
      sessionId,
      requestId: `prompt-${Date.now()}`,
      text,
    }));

  sendPrompt();
  let lastErr = "";
  while (Date.now() < deadline) {
    const evt = await app
      .waitFor(
        (m: any) =>
          m._streamId === streamId &&
          m.sessionId === sessionId &&
          (m.type === "agent:turn-start" || m.type === "agent:error"),
        deadline - Date.now(),
      )
      .catch(() => null);
    // Null is the budget elapsing, not a lost prompt — fall through to the
    // throw rather than re-sending.
    if (!evt) break;
    if (evt.type === "agent:turn-start") return evt;
    lastErr = evt.error?.message ?? "";
    // Only the warm-up race is retryable; a real driver error must surface.
    if (!/not started/i.test(lastErr)) {
      throw new Error(`agent:error before turn-start: ${lastErr}`);
    }
    await Bun.sleep(500);
    sendPrompt();
  }
  throw new Error(`no agent:turn-start within budget (last error: ${lastErr})`);
}
