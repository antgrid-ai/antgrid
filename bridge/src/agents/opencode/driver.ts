import { OpencodeDriver, type OpencodeClientLike } from "./chat-backend";
import { spawnOpencode } from "./spawn";
import type { StructuredDriver } from "../../structured/structured-manager";
import type { DriverCtx } from "../types";

export function createDriver(ctx: DriverCtx): StructuredDriver {
  // spawnOpencode is async (it awaits server startup); the driver's start()
  // performs the await via a thunked client. Build a lazy OpencodeClientLike
  // that resolves the spawn on first use so the factory stays synchronous.
  let spawned: Promise<Awaited<ReturnType<typeof spawnOpencode>>> | null = null;
  const ensure = () => (spawned ??= spawnOpencode({ cwd: ctx.projectPath }));
  const lazy: OpencodeClientLike = {
    createSession: async (o) => (await ensure()).client.createSession(o),
    messages: async (s) => (await ensure()).client.messages(s),
    deleteMessage: async (s, m) => (await ensure()).client.deleteMessage(s, m),
    prompt: async (s, t, o) => (await ensure()).client.prompt(s, t, o),
    abort: async (s) => (await ensure()).client.abort(s),
    summarize: async (s, m) => (await ensure()).client.summarize(s, m),
    replyPermission: async (s, id, r) => (await ensure()).client.replyPermission(s, id, r),
    replyQuestion: async (id, a) => (await ensure()).client.replyQuestion(id, a),
    listCommands: async () => (await ensure()).client.listCommands(),
    listAgents: async () => (await ensure()).client.listAgents(),
    listProviders: async () => (await ensure()).client.listProviders(),
    command: async (s, o) => (await ensure()).client.command(s, o),
    events: async function* () { yield* (await ensure()).client.events(); },
    // Await the real teardown (server exit) so an in-app `opencode
    // upgrade` never runs while the SDK server still holds the binary.
    // Nothing spawned yet → nothing to wait for.
    dispose: async () => { await spawned?.then((s) => s.client.dispose()); },
  };
  ctx.emitUpdateCheck();
  return new OpencodeDriver({
    sessionId: ctx.sessionId, client: lazy, sendMessage: ctx.send, onTitle: ctx.onTitle,
    onLifecycle: ctx.onLifecycle,
  });
}
