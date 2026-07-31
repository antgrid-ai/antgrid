// A tool supports structured (chat-mode) sessions exactly when its registry
// entry carries a driver — presence IS the capability, so there is no second
// list to keep in lockstep with the driver wiring.
// This is also the source for the `chatCapable` flag stamped onto `agent:tools`
// / `tools:list` entries (host-server.ts) — the wire advert is authoritative
// for the app; app/lib/providers/new_session_picker.dart's static
// newSessionAgentSupportsChat is only a fallback for older bridges or while
// the wire data hasn't loaded yet.
import { agentSpec } from "../agents/registry";

export function isChatCapableTool(tool: string | undefined): boolean {
  return tool !== undefined && agentSpec(tool)?.driver !== undefined;
}
