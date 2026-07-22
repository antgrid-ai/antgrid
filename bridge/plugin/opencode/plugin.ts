// Antgrid opencode plugin: forwards three independent streams to the bridge —
// the live conversation title (session.updated) to /session-title, app
// notifications (permission/idle/error) to /notify, and Handler triggers
// (session.idle → turn_end, permission.asked → awaiting_input) to /handler-event.
// Runs inside opencode's own Bun runtime, so we use fetch (no node).
// Fire-and-forget; correlation via the ANTGRID_TERMINAL_ID env.
import type { Plugin } from "@opencode-ai/plugin";

// opencode awaits this event handler, so an unbounded fetch would stall a turn
// on a bridge that accepts the connection and then hangs (a dead bridge already
// fails fast with ECONNREFUSED). Every post below is disposable; the turn is not.
const BRIDGE_TIMEOUT_MS = 2000;

export const AntgridSessionNamer: Plugin = async () => ({
  event: async ({ event }: { event: any }) => {
    const port = process.env.ANTGRID_API_PORT;
    if (!port) return;
    const type = event?.type;
    // Read before the notify block: a notification must still fire without an id,
    // just without a session name. The title and handler paths below genuinely
    // cannot correlate without one, so their guard stays where it is.
    const terminalId = process.env.ANTGRID_TERMINAL_ID;

    // Notification forwarding: map select events onto the app's notify channel.
    // session.idle here means "waiting for you", not task_complete — we never
    // claim a completion we can't verify. This is NOT mutually exclusive with the
    // handler trigger below: session.idle fires both (notify the user AND wake the
    // supervisor), so we don't early-return after a notify.
    const NOTIFY: Record<string, string> = {
      "permission.updated": "permission_request",
      "session.idle": "idle",
      "session.error": "error",
    };
    const notifyType = NOTIFY[type];
    if (notifyType) {
      try {
        await fetch(`http://127.0.0.1:${port}/notify`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ type: notifyType, ...(terminalId ? { terminalId } : {}) }),
          signal: AbortSignal.timeout(BRIDGE_TIMEOUT_MS),
        });
      } catch { /* bridge gone */ }
    }

    // Title + handler forwarding both correlate by terminal id.
    if (!terminalId) return;

    if (type === "session.updated") {
      const info = event.properties?.info ?? event.info;
      const sessionId = info?.id;
      const title = info?.title;
      // The id alone is enough to resume; forward it even before opencode has
      // named the conversation (title arrives on a later session.updated). The
      // bridge captures the id unconditionally and uses the title only if present.
      if (!sessionId) return;
      try {
        await fetch(`http://127.0.0.1:${port}/session-title`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ terminalId, sessionId, title: title || undefined, agent: "opencode" }),
          signal: AbortSignal.timeout(BRIDGE_TIMEOUT_MS),
        });
      } catch { /* bridge gone — next event retries */ }
      return;
    }

    // Both names are handled defensively: opencode has used both forms across versions
    // and the stable name is not yet settled (guard against event-name drift).
    const handlerEvent =
      type === "session.idle" || type === "session.status:idle" ? "turn_end"
      : type === "permission.asked" ? "awaiting_input"
      : null;
    if (!handlerEvent) return;
    try {
      await fetch(`http://127.0.0.1:${port}/handler-event`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ terminalId, agent: "opencode", event: handlerEvent }),
        signal: AbortSignal.timeout(BRIDGE_TIMEOUT_MS),
      });
    } catch { /* fire-and-forget */ }
  },
});
