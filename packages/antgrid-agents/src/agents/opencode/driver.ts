import { OpencodeDriver, type OpencodeClientLike } from "./chat-backend";
import { spawnOpencode } from "./spawn";
import type { StructuredDriver } from "../../structured/structured-driver";
import type { DriverCtx } from "../types";

export function createDriver(ctx: DriverCtx, spawn = spawnOpencode): StructuredDriver {
  // spawnOpencode is async (it awaits server startup); the driver's start()
  // performs the await via a thunked client. Build a lazy OpencodeClientLike
  // that resolves the spawn on first use so the factory stays synchronous.
  let spawned: Promise<Awaited<ReturnType<typeof spawnOpencode>>> | null = null;
  let closed = false;
  const ensure = () => {
    if (closed) throw new Error("OpenCode backend is disposed");
    if (!spawned) {
      spawned = spawn({ cwd: ctx.projectPath });
      ctx.emitUpdateCheck();
    }
    return spawned;
  };
  const invoke = async <T>(operation: (client: OpencodeClientLike) => Promise<T>): Promise<T> => {
    const resource = await ensure();
    if (closed) throw new Error("OpenCode backend is disposed");
    return operation(resource.client);
  };
  const lazy: OpencodeClientLike = {
    createSession: (o) => invoke((client) => client.createSession(o)),
    messages: (s) => invoke((client) => client.messages(s)),
    deleteMessage: (s, m) => invoke((client) => client.deleteMessage(s, m)),
    prompt: (s, t, o) => invoke((client) => client.prompt(s, t, o)),
    abort: (s) => invoke((client) => client.abort(s)),
    summarize: (s, m) => invoke((client) => client.summarize(s, m)),
    replyPermission: (s, id, r) => invoke((client) => client.replyPermission(s, id, r)),
    replyQuestion: (id, a) => invoke((client) => client.replyQuestion(id, a)),
    listCommands: () => invoke((client) => client.listCommands()),
    listAgents: () => invoke((client) => client.listAgents()),
    listProviders: () => invoke((client) => client.listProviders()),
    command: (s, o) => invoke((client) => client.command(s, o)),
    events: async function* () {
      const resource = await ensure();
      if (!closed) yield* resource.client.events();
    },
    // Await the real teardown (server exit) so an in-app `opencode
    // upgrade` never runs while the SDK server still holds the binary.
    // Nothing spawned yet → nothing to wait for.
    dispose: async () => { closed = true; await spawned?.then((s) => s.client.dispose()); },
  };
  return new OpencodeDriver({
    sessionId: ctx.sessionId, client: lazy, sendMessage: ctx.send,
    onLifecycle: ctx.onLifecycle,
  });
}
