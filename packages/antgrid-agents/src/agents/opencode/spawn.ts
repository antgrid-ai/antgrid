import { OpenCode, type ModelRef } from "@opencode/client";
import { OpencodeStartupError, startOpencodeServer, type OpencodeServerOptions } from "./server";
import type { OpencodeClientLike, OpencodePromptOpts } from "./chat-backend";
import { normalizeMessage, OpencodeV2Events } from "./v2-events";

// A location's registries load well under a second after it boots; this waits up to three.
const REGISTRY_POLLS = 30;
const REGISTRY_POLL_MS = 100;

export interface SpawnedOpencode {
  client: OpencodeClientLike;
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
  // A location loads its agent and command registries after it boots, and the
  // list routes answer before that with nothing (agents from 2.2.7, commands
  // since 2.0). OpenCode always has built-in agents, so the first non-empty
  // agent list is the sign both have loaded. Bounded: a slow load still leaves
  // the session usable, only without those pickers.
  let registries: Promise<void> | undefined;
  const registriesLoaded = () => registries ??= (async () => {
    for (let attempt = 0; attempt < REGISTRY_POLLS; attempt++) {
      if ((await client.agent.list({ location }, request)).data.length) return;
      await Bun.sleep(REGISTRY_POLL_MS);
    }
  })().catch((error) => {
    registries = undefined;
    throw error;
  });

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
          ...(cursor ? { cursor } : { order: "asc", limit: 200 }),
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
    listCommands: async () => {
      // An agent route that fails must not take the command list down with it.
      await registriesLoaded().catch(() => {});
      return (await client.command.list({ location }, request)).data;
    },
    listAgents: async () => {
      await registriesLoaded();
      return (await client.agent.list({ location }, request)).data.map((agent) => ({ ...agent, name: agent.id }));
    },
    listProviders: async () => {
      const [providers, models] = await Promise.all([
        client.provider.list({ location }, request), client.model.list({ location }, request),
      ]);
      const byProvider = Map.groupBy(models.data.filter((model) => model.enabled), (model) => model.providerID);
      return providers.data.filter((provider) => provider.activation !== "disabled").map((provider) => ({
        ...provider, models: Object.fromEntries((byProvider.get(provider.id) ?? [])
          .map((model) => [model.id, { ...model, variants: Object.fromEntries(model.variants.map((v) => [v.id, v])) }])),
      }));
    },
    command: async (sessionID, command) => {
      await select(sessionID, { agent: command.agent, model: command.model, variant: command.variant });
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
    replyForm: async (sessionID, formID, answer) => {
      if (answer === null) await client.session.form.cancel({ sessionID, formID }, request);
      else await client.session.form.reply({ sessionID, formID, answer }, request);
    },
    events: async function* () {
      for await (const event of client.event.subscribe({ signal: lifetime.signal })) yield* events.normalize(event);
      if (exited && !disposed) throw new Error("OpenCode server exited");
    },
    dispose: () => { disposed = true; lifetime.abort(); return server.close(); },
  };

  return { client: like };
}
