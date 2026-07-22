import { createOpencodeServer, createOpencodeClient } from "@opencode-ai/sdk/v2";
import type { OpencodeClientLike, OpencodeEvent } from "./opencode-driver";

export interface SpawnedOpencode {
  client: OpencodeClientLike;
}

// The v2 client returns errors as data ({ data, error, response }) instead of
// throwing. Unwrap so a non-2xx / errored call rejects the promise instead of
// being silently swallowed; return the success payload. A route the binary
// doesn't serve (version skew) lands here as a non-2xx / text/html fall-through
// and fails loudly at call time — no startup version gate needed.
function unwrap(res: any): any {
  if (res?.error !== undefined || (res?.response && !res.response.ok)) {
    throw new Error(`opencode request failed (status ${res?.response?.status ?? "unknown"})`);
  }
  return res?.data;
}

// Resolve once the server URL stops accepting connections (proof its process is
// gone), bounded so a wedged teardown can't block a caller forever. An in-app
// `opencode upgrade` replaces the on-disk binary, which on Windows fails while
// the server (the SAME binary — the SDK spawns PATH `opencode`) still holds it;
// so quiesce MUST await this before the updater runs. On Windows the SDK's
// close() already blocks on `taskkill /F /T`, so the first probe fails
// immediately; on posix it waits out the SIGTERM.
async function waitServerGone(url: string, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await fetch(url, { signal: AbortSignal.timeout(400) });
    } catch {
      return; // connection refused / aborted → listener down
    }
    await Bun.sleep(100);
  }
}

/**
 * Spawn `opencode serve` (OS-assigned port) and wrap its SDK client as an
 * OpencodeClientLike. The server runs the same binary as the CLI, so provider
 * auth is read from the shared ~/.local/share/opencode/auth.json — no auth work
 * here. `directory` scopes every call to this project's root.
 *
 * Uses the SDK's `/v2` export deliberately. The events are a red herring here:
 * the binary streams ALL events on a single unfiltered `/event` bus regardless
 * of SDK generation, so the default (`.`) export would still receive
 * permission.asked / question.asked / message.part.delta at runtime — it just
 * lacks types for them. What the `/v2` surface actually buys is the matching
 * *route* shapes (and the typed question.reply call); those routes are the part
 * that must line up with the running server. See the driver's OpencodeEvent note.
 */
export async function spawnOpencode(opts: { cwd: string }): Promise<SpawnedOpencode> {
  const server = await createOpencodeServer({ hostname: "127.0.0.1", port: 0 });
  const client = createOpencodeClient({ baseUrl: server.url, directory: opts.cwd });
  const directory = opts.cwd;

  const like: OpencodeClientLike = {
    createSession: async ({ title, parentID }) => {
      const data = unwrap(await client.session.create({ directory, title, parentID }));
      return data?.id ?? "";
    },
    messages: async (sessionId) => {
      // v2 SDK: client.session.messages returns Array<{ info, parts }> directly
      // (openapi operationId session.messages, route /session/{sessionID}/message).
      const data = unwrap(await client.session.messages({ sessionID: sessionId, directory }));
      return Array.isArray(data) ? data : [];
    },
    deleteMessage: async (sessionId, messageId) => {
      unwrap(await client.session.deleteMessage({ sessionID: sessionId, messageID: messageId, directory }));
    },
    prompt: async (sessionId, text, opts) => {
      unwrap(await client.session.promptAsync({
        sessionID: sessionId, directory,
        parts: [{ type: "text", text }],
        ...(opts?.model ? { model: opts.model } : {}),
        ...(opts?.agent ? { agent: opts.agent } : {}),
        ...(opts?.variant ? { variant: opts.variant } : {}),
      }));
    },
    listCommands: async () => {
      const data = unwrap(await client.command.list({ directory }));
      return Array.isArray(data) ? data : [];
    },
    listAgents: async () => {
      const data = unwrap(await client.app.agents({ directory }));
      return Array.isArray(data) ? data : [];
    },
    listProviders: async () => {
      const data = unwrap(await client.provider.list({ directory }));
      return { all: data?.all ?? [], default: data?.default ?? {}, connected: data?.connected ?? [] };
    },
    command: async (sessionId, opts) => {
      unwrap(await client.session.command({ sessionID: sessionId, directory, ...opts }));
    },
    abort: async (sessionId) => {
      unwrap(await client.session.abort({ sessionID: sessionId, directory }));
    },
    summarize: async (sessionId, model) => {
      unwrap(await client.session.summarize({ sessionID: sessionId, directory, providerID: model.providerID, modelID: model.modelID }));
    },
    replyPermission: async (_sessionId, permissionId, response) => {
      // v2 keys the reply by requestID (the permission id) alone — sessionID isn't needed.
      unwrap(await client.permission.reply({ requestID: permissionId, directory, reply: response }));
    },
    replyQuestion: async (questionId, answer) => {
      // QuestionAnswer = string[] (selected labels); v1 asks one question, so we
      // send a single answer = the selected label(s).
      const labels = Array.isArray(answer) ? answer : [answer];
      unwrap(await client.question.reply({ requestID: questionId, directory, answers: [labels] }));
    },
    events: async function* () {
      const sub = await client.event.subscribe({ directory });
      for await (const evt of sub.stream as AsyncIterable<OpencodeEvent>) yield evt;
    },
    dispose: async () => { server.close(); await waitServerGone(server.url); },
  };

  return { client: like };
}
