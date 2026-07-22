// Single source of truth for which agent tools have a structured (chat-mode)
// driver. Keep in lockstep with the driverFactory branches in agent-core.ts.
// This is also the source for the `chatCapable` flag stamped onto `agent:tools`
// / `tools:list` entries (host-server.ts) — the wire advert is authoritative
// for the app; app/lib/providers/new_session_picker.dart's static
// newSessionAgentSupportsChat is only a fallback for older bridges or while
// the wire data hasn't loaded yet.
const CHAT_CAPABLE = new Set(["codex", "opencode", "claude-code"]);

export function isChatCapableTool(tool: string | undefined): boolean {
  return tool !== undefined && CHAT_CAPABLE.has(tool);
}
