import type { HookCommand } from "./hook-command";
import { AsyncLocalStorage } from "node:async_hooks";

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

const hostContext = new AsyncLocalStorage<AgentHostServices>();

/** Bind synchronous entry and asynchronous continuations to one runtime's services. */
export function withAgentHost<T>(host: AgentHostServices, operation: () => T): T {
  return hostContext.run(host, operation);
}

export function agentHost(): AgentHostServices {
  const services = hostContext.getStore();
  if (!services) throw new Error("Agent host services must be configured before launching an adapter");
  return services;
}

function scopedLogger(bindings: Record<string, unknown>): AgentLogger {
  const write = (level: "debug" | "info" | "warn" | "error", args: any[]) => {
    hostContext.getStore()?.logger.child(bindings)[level](...args);
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

/** Callback-based SDKs may re-enter a driver outside the context of its startup. */
export function bindAgentHost<T extends object>(host: AgentHostServices, value: T): T {
  const cache = new Map<PropertyKey, unknown>();
  return new Proxy(value, {
    get(target, key) {
      const member = Reflect.get(target, key, target);
      if (typeof member !== "function") return member;
      if (!cache.has(key)) cache.set(key, (...args: unknown[]) => withAgentHost(host, () => member.apply(target, args)));
      return cache.get(key);
    },
  });
}

export function bindAgentOperations<T>(host: AgentHostServices, value: T): T {
  if (Array.isArray(value)) return value.map((item) => bindAgentOperations(host, item)) as T;
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value).map(([key, member]) => [key,
    typeof member === "function"
      ? (...args: unknown[]) => withAgentHost(host, () => member.apply(value, args))
      : bindAgentOperations(host, member),
  ])) as T;
}
