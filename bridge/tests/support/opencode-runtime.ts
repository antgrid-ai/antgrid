import { agentRuntime } from "../../src/agent-runtime";
import { withAgentHost } from "antgrid-agents/host";
import type { TerminalLaunchRequest } from "antgrid-agents/terminal-launch";
import { prepareOpencodeTerminal } from "../../../packages/antgrid-agents/src/agents/opencode/terminal";

// Session-manager tests exercise argv and PTY ownership without requiring a
// developer-installed agent. The package suite owns the real version gate.
export const opencodeTestRuntime = {
  ...agentRuntime,
  prepareTerminal: (request: TerminalLaunchRequest) => (request.tool ?? request.configured.name) === "opencode"
    ? withAgentHost(agentRuntime.host, () => prepareOpencodeTerminal(request, async () => "2.2.5"))
    : agentRuntime.prepareTerminal(request),
};
