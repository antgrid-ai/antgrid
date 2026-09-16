// A tool supports structured (chat-mode) sessions exactly when its registry
// entry carries a driver — presence IS the capability, so there is no second
// list to keep in lockstep with the driver wiring.
// This is also the source for the `chatCapable` flag stamped onto `agent:tools`
// / `tools:list` entries (host-server.ts) — the target machine's advert is
// authoritative for the app. Its only fallback is the persisted agent catalog
// (the sibling `agents[]` descriptor, merged into app/lib/providers/
// agent_catalog.dart), which answers for a target whose bridge predates the
// flag or hasn't spoken yet; see agentSupportsChatResolved in
// app/lib/providers/new_session_picker.dart.
import { agentSpec } from "../agents/registry";

export function isChatCapableTool(tool: string | undefined): boolean {
  return tool !== undefined && agentSpec(tool)?.driver !== undefined;
}
