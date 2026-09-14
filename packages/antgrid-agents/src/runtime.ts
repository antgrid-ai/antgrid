import { z } from "zod";
import type { AgentHostServices } from "./host";
import { withAgentHost, bindAgentHost, bindAgentOperations } from "./host";
import type { AgentRegistry } from "./agents/create-registry";
import { snapshotDefinition } from "./agents/create-registry";
import type { AgentSpec, DriverCtx, TitleArgs } from "./agents/types";
import { pickHeadlessFrom } from "./agents/types";
import { prepareCliTerminalLaunch, type TerminalLaunchRequest } from "./agents/terminal-launch";
import { AgentOutputEventSchema } from "./protocol";
import { resolveApprovalPolicy } from "./agent-approval-policy";

export const AGENT_API_VERSION = 1;
const Operation = z.custom<(...args: any[]) => any>((value) => typeof value === "function", "Expected an adapter operation");
const SpecRegistrationSchema = z.object({
  label: z.string().min(1),
  hookName: z.string().min(1).nullable(),
  cli: z.object({ bin: z.string().min(1), args: z.array(z.string()).optional(), resume: Operation.optional(), initialPrompt: Operation.optional(), env: Operation.optional(), nativeForkArgs: Operation.optional(), approvalBypassArgs: z.array(z.string()).optional() }).passthrough().optional(),
  driver: Operation.optional(), prepareTerminal: Operation.optional(), discover: Operation.optional(),
  fork: z.object({ kind: z.enum(["native-fork", "native-transcript", "terminal-transcript"]), handoff: Operation }).passthrough(),
  approvalPolicies: z.object({ bypass: z.object({ terminal: z.literal(true).optional(), chat: z.literal(true).optional(), risk: z.enum(["bypasses-approvals", "bypasses-approvals-and-sandbox"]) }).optional() }),
  headless: z.partialRecord(z.enum(["sealed", "readonly", "transcript"]), z.union([
    z.object({ cmd: Operation, noHistory: z.enum(["flag", "ephemeral-store", "stateless"]) }).passthrough(),
    z.object({ run: Operation, noHistory: z.enum(["ephemeral-store", "stateless"]) }).passthrough(),
  ])).optional(),
}).passthrough();

export const AgentDiscoverySchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("available"), executable: z.string().optional(), version: z.string().optional() }),
  z.object({ status: z.literal("unavailable"), reason: z.string().min(1) }),
]);
export type AgentDiscovery = z.infer<typeof AgentDiscoverySchema>;

export interface AgentDefinition {
  readonly apiVersion: typeof AGENT_API_VERSION;
  readonly hookName: string | null;
  create(host: AgentHostServices): AgentSpec;
}

/** All operations and caches belong to the registry/host pair that constructed them. */
export function createAgentRuntime(options: {
  registry: AgentRegistry<string, AgentDefinition>;
  host: AgentHostServices;
}) {
  const host = Object.freeze({ ...options.host });
  const agents: Record<string, AgentSpec> = Object.create(null);
  for (const [id, definition] of Object.entries(options.registry.agents)) {
    if (definition.apiVersion !== AGENT_API_VERSION) throw new Error(`Unsupported agent API version for ${id}`);
    if (typeof definition.create !== "function") throw new Error(`Agent ${id} has no factory`);
    const spec = withAgentHost(host, () => definition.create(host));
    SpecRegistrationSchema.parse(spec);
    for (const key of ["driver", "prepareTerminal", "discover", "observeTitles", "resolveTitle"] as const) {
      if (spec[key] !== undefined && typeof spec[key] !== "function") throw new Error(`Invalid agent operation ${id}.${key}`);
    }
    if (spec.fork.kind === "native-fork" && !spec.prepareTerminal && !spec.cli?.nativeForkArgs) throw new Error(`Agent ${id} declares native fork without an invocation`);
    if (spec.hookName !== definition.hookName) throw new Error(`Agent hook alias changed during construction: ${id}`);
    agents[id] = snapshotDefinition(bindAgentOperations(host, spec));
  }
  Object.freeze(agents);
  const get = (id: string): AgentSpec | undefined => Object.hasOwn(agents, id) ? agents[id] : undefined;
  const discovery = new Map<string, Promise<AgentDiscovery>>();
  const runtime = {
    agents,
    byHookName: options.registry.byHookName,
    host,
    get,
    isChatCapable: (id: string) => get(id)?.driver !== undefined,
    judgeCapable: (id: string) => pickHeadlessFrom(get(id)?.headless, "repo") !== null,
    handlerObservable(id: string | undefined, mode: "terminal" | "chat") {
      const spec = id ? get(id) : undefined;
      return mode === "chat" ? !!spec?.driver : spec?.observation?.handler === true;
    },
    createDriver(id: string, context: DriverCtx) {
      const factory = get(id)?.driver;
      if (!factory) throw new Error(`Agent ${id} does not support chat`);
      return bindAgentHost(host, withAgentHost(host, () => factory({ ...context, send: (message) => {
        context.send(AgentOutputEventSchema.parse({ ...message, sessionId: context.sessionId }));
      } })));
    },
    resolveApprovalPolicy: (id: string, mode: "terminal" | "chat", policy: import("./agents/types").ApprovalPolicy) => resolveApprovalPolicy(id, mode, policy, get),
    prepareTerminal(request: TerminalLaunchRequest) {
      const spec = get(request.tool ?? request.configured.name);
      return withAgentHost(host, () => {
        if (request.tool && !spec) throw new Error(`unknown agent: ${request.tool}`);
        if (!request.customCommand && spec) {
          resolveApprovalPolicy(request.tool ?? request.configured.name, "terminal", request.approvalPolicy, get);
          if (request.conversation.kind === "fork" && !spec.conversations?.terminal?.includes("fork")) throw new Error("Agent does not support native terminal forks");
        }
        if (!request.customCommand && spec?.prepareTerminal) return spec.prepareTerminal(request);
        return prepareCliTerminalLaunch(request, { get, host });
      });
    },
    discover(id: string, context: { path?: string; signal?: AbortSignal; refresh?: boolean } = {}): Promise<AgentDiscovery> {
      const spec = get(id);
      if (!spec) return Promise.resolve({ status: "unavailable", reason: "Agent is not registered" });
      const key = JSON.stringify([id, context.path ?? process.env.PATH ?? ""]);
      if (context.refresh) discovery.delete(key);
      if (!context.signal && discovery.has(key)) return discovery.get(key)!;
      const pending = Promise.resolve().then(async () => {
        context.signal?.throwIfAborted();
        const result = spec.discover
          ? await spec.discover(context)
          : await discoverCli(spec.cli?.bin, context.path, spec.discoveryPaths?.());
        context.signal?.throwIfAborted();
        return AgentDiscoverySchema.parse(result);
      }).catch((error): AgentDiscovery => ({ status: "unavailable", reason: error instanceof Error ? error.message : String(error) }));
      if (!context.signal) discovery.set(key, pending);
      return pending;
    },
    invalidateDiscovery() { discovery.clear(); },
    async resolveStructuredTitle(alias: string | undefined, args: { sessionId: string; transcriptPath?: string }, extra: Omit<TitleArgs, "sessionId" | "transcriptPath"> = {}) {
      const id = alias ? options.registry.byHookName[alias] : undefined;
      try { return id ? await withAgentHost(host, () => get(id)?.resolveTitle?.({ ...args, ...extra })) ?? null : null; }
      catch (error) { host.logger.warn({ error }, "Agent title resolution failed"); return null; }
    },
  };
  return Object.freeze(runtime);
}

export type AgentRuntime = ReturnType<typeof createAgentRuntime>;

export async function discoverCli(binary: string | undefined, path = process.env.PATH ?? "", extraPaths: readonly string[] = []): Promise<AgentDiscovery> {
  if (!binary) return { status: "unavailable", reason: "No executable or discovery operation configured" };
  const delimiter = process.platform === "win32" ? ";" : ":";
  const executable = Bun.which(binary, { PATH: [path, ...extraPaths].join(delimiter) });
  return executable ? { status: "available", executable } : { status: "unavailable", reason: `${binary} was not found on PATH` };
}
