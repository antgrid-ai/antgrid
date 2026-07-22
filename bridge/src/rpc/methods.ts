import { z } from "zod";
import type { MessageBus } from "../message-bus";
import { createMessage, type RpcRequest, type RpcResponse } from "../protocol";
import { StateSnapshotParams, stateSnapshotHandler } from "./state-snapshot";

interface MethodDef {
  paramsSchema: z.ZodTypeAny;
  handler: (bus: MessageBus, params: unknown) => unknown | Promise<unknown>;
}

const METHODS: Record<string, MethodDef> = {
  "state.snapshot": {
    paramsSchema: StateSnapshotParams,
    handler: stateSnapshotHandler as MethodDef["handler"],
  },
};

/** Test seam — register an ad-hoc method. Do not use from production code. */
export function _registerMethodForTest(
  name: string,
  def: { paramsSchema: z.ZodTypeAny; handler: (bus: MessageBus, params: unknown) => unknown | Promise<unknown> },
): () => void {
  METHODS[name] = def as MethodDef;
  return () => delete METHODS[name];
}

export async function dispatchRpc(bus: MessageBus, req: RpcRequest): Promise<RpcResponse> {
  const def = METHODS[req.method];
  if (!def) {
    return createMessage("response", {
      requestId: req.requestId,
      ok: false,
      error: { code: "E_UNKNOWN_METHOD", message: `unknown method: ${req.method}` },
    });
  }
  const parsed = def.paramsSchema.safeParse(req.params ?? {});
  if (!parsed.success) {
    return createMessage("response", {
      requestId: req.requestId,
      ok: false,
      error: {
        code: "E_BAD_PARAMS",
        message: parsed.error.issues.map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`).join("; "),
      },
    });
  }
  try {
    const result = await def.handler(bus, parsed.data);
    return createMessage("response", { requestId: req.requestId, ok: true, result });
  } catch (e) {
    return createMessage("response", {
      requestId: req.requestId,
      ok: false,
      error: { code: "E_HANDLER", message: e instanceof Error ? e.message : String(e) },
    });
  }
}
