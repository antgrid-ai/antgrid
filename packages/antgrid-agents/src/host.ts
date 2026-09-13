import type { HookCommand } from "./hook-command";

export interface AgentLogger {
  child(bindings: Record<string, unknown>): AgentLogger;
  debug(...args: any[]): void;
  info(...args: any[]): void;
  warn(...args: any[]): void;
  error(...args: any[]): void;
}

export interface AgentHostServices {
  logger: AgentLogger;
  stateDirectory(): string;
  hookCommand(): HookCommand;
  killChildTree(child: { readonly pid?: number; kill(): unknown }): Promise<void>;
  stripInheritedCertOverrides(env: Record<string, string>): Record<string, string>;
}

let services: AgentHostServices | undefined;

/** Bind host policy once at application startup, before starting any adapters. */
export function configureAgentHost(host: AgentHostServices): void {
  services = host;
}

export function agentHost(): AgentHostServices {
  if (!services) throw new Error("Agent host services must be configured before launching an adapter");
  return services;
}

function scopedLogger(bindings: Record<string, unknown>): AgentLogger {
  const write = (level: "debug" | "info" | "warn" | "error", args: any[]) => {
    services?.logger.child(bindings)[level](...args);
  };
  return {
    child: (extra) => scopedLogger({ ...bindings, ...extra }),
    debug: (...args) => write("debug", args),
    info: (...args) => write("info", args),
    warn: (...args) => write("warn", args),
    error: (...args) => write("error", args),
  };
}

export const logger = scopedLogger({});
export const resolveAbDir = () => agentHost().stateDirectory();
export const resolveHookCommand = () => agentHost().hookCommand();
export const killChildTree: AgentHostServices["killChildTree"] = (child) => agentHost().killChildTree(child);
export const stripInheritedCertOverrides: AgentHostServices["stripInheritedCertOverrides"] = (env) => agentHost().stripInheritedCertOverrides(env);
export const processGroupSpawn = (platform: NodeJS.Platform = process.platform) => ({ detached: platform !== "win32" });
