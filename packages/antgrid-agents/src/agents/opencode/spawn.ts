import { OpenCode, type ModelRef } from "@opencode/client";
import { OpencodeStartupError, startOpencodeServer, type OpencodeServerOptions } from "./server";
import type { OpencodeClientLike, OpencodePromptOpts } from "./chat-backend";
import { normalizeMessage, OpencodeV2Events } from "./v2-events";
import { McpElicitationContentSchema } from "../../structured/mcp-elicitation";

export interface SpawnedOpencode {
  client: OpencodeClientLike;
}

// A slow HTTP response is not proof the listener stopped. Only a refused
// connection confirms closure; timeout must remain a teardown failure.
export async function waitServerGone(
  url: string,
  timeoutMs = 5_000,
  probe: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await probe(url, { signal: AbortSignal.timeout(400) });
    } catch (error) {
      const failure = error as { code?: string; cause?: { code?: string } };
      const code = failure.code ?? failure.cause?.code;
      if (code === "ECONNREFUSED" || code === "ConnectionRefused") return;
    }
    await Bun.sleep(100);
  }
  throw new Error("OpenCode server did not stop accepting connections before teardown timed out");
}

export async function spawnOpencode(opts: OpencodeServerOptions): Promise<SpawnedOpencode> {
  const server = await startOpencodeServer(opts);
  try { return connectOpencode(server, opts.cwd); }
  catch (error) {
    await server.close();
    throw new OpencodeStartupError(error instanceof Error ? error.message : String(error), { cause: error });
  }
}

export function connectOpencode(server: Awaited<ReturnType<typeof startOpencodeServer>>, cwd: string): SpawnedOpencode {
  const client = OpenCode.make({ baseUrl: server.url, headers: server.headers });
  const lifetime = new AbortController();
  let disposed = false;
  let exited = false;
  const serverExited = () => {
    exited = true;
    if (!disposed) lifetime.abort(new Error("OpenCode server exited"));
  };
  // An EOF can look like a normal subscription close. Tie it to the owned
  // process so an unexpected exit fails the active turn.
  void server.exited?.then(serverExited, serverExited);
  const request = { signal: lifetime.signal };
  const location = { directory: cwd };
  const forms = new Map<string, string>();
  const events = new OpencodeV2Events();
  const select = async (sessionID: string, selection?: OpencodePromptOpts) => {
    if (selection?.agent) await client.session.switchAgent({ sessionID, agent: selection.agent }, request);
    if (!selection?.model && !selection?.variant) return;
    const current = selection.model
      ? { id: selection.model.modelID, providerID: selection.model.providerID }
      : (await client.session.get({ sessionID }, request)).model;
    if (!current) throw new Error("Choose an OpenCode model before setting its reasoning effort");
    const model: ModelRef = { ...current, ...(selection.variant ? { variant: selection.variant } : {}) };
    await client.session.switchModel({ sessionID, model }, request);
  };

  const like: OpencodeClientLike = {
    createSession: async ({ title, parentID }) => {
      const data = await client.session.create({ location, title, parentID }, request);
      return data.id;
    },
    messages: async (sessionId) => {
      const messages: ReturnType<typeof normalizeMessage>[] = [];
      let cursor: string | undefined;
      do {
        const page = await client.message.list({ sessionID: sessionId,
          ...(cursor ? { cursor } : { order: "asc", limit: 100 }),
        }, request);
        messages.push(...page.data.map(normalizeMessage));
        const next = page.cursor.next ?? undefined;
        if (next && next === cursor) throw new Error("OpenCode returned a repeated history cursor");
        cursor = next;
      } while (cursor);
      return messages;
    },
    revertMessages: async (sessionID, messageID) => {
      await client.session.revert.stage({ sessionID, messageID, files: false }, request);
      await client.session.revert.commit({ sessionID }, request);
    },
    prompt: async (sessionID, text, selection) => {
      await select(sessionID, selection);
      await client.session.prompt({ sessionID, text }, request);
    },
    listCommands: async () => (await client.command.list({ location }, request)).data,
    listAgents: async () => (await client.agent.list({ location }, request)).data.map((agent) => ({ ...agent, name: agent.id })),
    listProviders: async () => {
      const [providers, models] = await Promise.all([
        client.provider.list({ location }, request), client.model.list({ location }, request),
      ]);
      const all = providers.data.filter((provider) => provider.activation !== "disabled").map((provider) => ({
        ...provider, models: Object.fromEntries(models.data.filter((model) => model.providerID === provider.id && model.enabled)
          .map((model) => [model.id, { ...model, variants: Object.fromEntries(model.variants.map((v) => [v.id, v])) }])),
      }));
      return { all, default: {}, connected: all.map((provider) => provider.id) };
    },
    command: async (sessionID, command) => {
      const separator = command.model?.indexOf("/") ?? -1;
      await select(sessionID, {
        agent: command.agent, variant: command.variant,
        ...(command.model && separator > 0 ? { model: {
          providerID: command.model.slice(0, separator), modelID: command.model.slice(separator + 1),
        } } : {}),
      });
      await client.session.command({ sessionID, name: command.command, text: command.arguments }, request);
    },
    abort: async (sessionID) => {
      await client.session.interrupt({ sessionID }, request);
    },
    summarize: async (sessionID) => {
      await client.session.compact({ sessionID }, request);
    },
    replyPermission: async (sessionID, requestID, decision) => {
      await client.permission.reply({ sessionID, requestID, decision }, request);
    },
    replyQuestion: async (questionId, answer) => {
      const sessionID = forms.get(questionId);
      if (!sessionID) throw new Error("OpenCode form is no longer pending");
      if (answer === null) await client.session.form.cancel({ sessionID, formID: questionId }, request);
      else await client.session.form.reply({ sessionID, formID: questionId,
        answer: McpElicitationContentSchema.parse(JSON.parse(String(answer))),
      }, request);
      forms.delete(questionId);
    },
    events: async function* () {
      for await (const event of client.event.subscribe({ signal: lifetime.signal })) {
        if (event.type === "form.created") forms.set(event.data.form.id, event.data.form.sessionID);
        if (event.type === "form.cancelled" || event.type === "form.replied") forms.delete(event.data.id);
        yield* events.normalize(event);
      }
      if (exited && !disposed) throw new Error("OpenCode server exited");
    },
    dispose: () => { disposed = true; lifetime.abort(); return server.close(); },
  };

  return { client: like };
}
