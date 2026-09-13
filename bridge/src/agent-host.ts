import { configureAgentHost } from "antgrid-agents/host";
import { logger } from "./logger";
import { resolveAbDir } from "./antgrid-dir";
import { resolveHookCommand } from "./hook-command";
import { killChildTree, stripInheritedCertOverrides } from "./terminal-session";

configureAgentHost({
  logger,
  stateDirectory: resolveAbDir,
  hookCommand: resolveHookCommand,
  killChildTree: (child) => killChildTree(child),
  stripInheritedCertOverrides: (env) => stripInheritedCertOverrides(env),
});
