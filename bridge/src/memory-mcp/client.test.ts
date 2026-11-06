import { expect, test } from "bun:test";
import { MemoryMcpClient, memoryApiIdentity } from "./client";

const finding = { content: "A useful observation", memory_type: "observation", scope: "project" };

test("memory client requires the inherited core port, durable session and live run", () => {
  expect(memoryApiIdentity({ ANTGRID_API_PORT: "1234", ANTGRID_TERMINAL_ID: "session", ANTGRID_RUN_ID: "run" })).toEqual({ base: "http://127.0.0.1:1234", terminalId: "session", runId: "run" });
  for (const port of ["", "0", "-1", "65536", "1.5", "${ANTGRID_API_PORT}", "1234/path"]) {
    expect(memoryApiIdentity({ ANTGRID_API_PORT: port, ANTGRID_TERMINAL_ID: "session", ANTGRID_RUN_ID: "run" })).toBeNull();
  }
  expect(memoryApiIdentity({ ANTGRID_API_PORT: "1234", ANTGRID_TERMINAL_ID: "session" })).toBeNull();
});

test("prepare precedes dispatch and a lost response reuses one durable key and payload", async () => {
  const calls: { op: string; body: Record<string, unknown> }[] = [];
  let saves = 0;
  const client = new MemoryMcpClient({
    operationKey: () => "durable-key", sleep: async () => {},
    request: async (op, body) => {
      calls.push({ op, body });
      if (op === "prepare") return { state: "pending" };
      if (++saves === 1) throw new Error("response lost after commit");
      return { id: "memory-id", outcome: "saved" };
    },
  });
  expect(await client.call("memory_save", finding)).toMatchObject({ id: "memory-id", operation_key: "durable-key" });
  expect(calls.map(call => call.op)).toEqual(["prepare", "save", "save"]);
  expect(calls.every(call => JSON.stringify(call.body) === JSON.stringify(calls[0]!.body))).toBe(true);
});

test("validation and terminal refusals never cause blind retries", async () => {
  const ops: string[] = [];
  const client = new MemoryMcpClient({ request: async op => { ops.push(op); return { error: { code: "PAUSED", message: "Paused" } }; } });
  expect(await client.call("memory_save", {})).toMatchObject({ error: { code: "INVALID_ARGUMENT" } });
  expect(ops).toEqual([]);
  expect(await client.call("memory_save", finding)).toMatchObject({ error: { code: "PAUSED" } });
  expect(ops).toEqual(["prepare"]);
});

test("save attempts stop at three and report unknown commit outcome", async () => {
  let attempts = 0;
  const client = new MemoryMcpClient({ operationKey: () => "pending-key", sleep: async () => {}, request: async op => {
    if (op === "prepare") return { state: "pending" };
    attempts++;
    throw new Error("no response");
  } });
  expect(await client.call("memory_save", finding)).toMatchObject({ error: { code: "UNKNOWN_OUTCOME" }, operation_key: "pending-key" });
  expect(attempts).toBe(3);
});

test("preparation failures and save retries share three total attempts", async () => {
  for (const failedPrepares of [1, 2]) {
    const calls: string[] = [];
    let prepares = 0;
    let saves = 0;
    const client = new MemoryMcpClient({ operationKey: () => "shared-key", sleep: async () => {}, request: async op => {
      calls.push(op);
      if (op === "prepare") {
        if (++prepares <= failedPrepares) throw new Error("prepare response lost");
        return { state: "pending" };
      }
      saves++;
      throw new Error("save response lost");
    } });
    expect(await client.call("memory_save", finding)).toMatchObject({ error: { code: "UNKNOWN_OUTCOME" }, operation_key: "shared-key" });
    expect(failedPrepares + saves).toBe(3);
    expect(calls).toEqual([...Array(failedPrepares + 1).fill("prepare"), ...Array(3 - failedPrepares).fill("save")]);
  }
});

test("the two-second overall deadline includes preparation and backoff", async () => {
  let now = 0;
  let attempts = 0;
  const client = new MemoryMcpClient({ now: () => now, sleep: async ms => { now += ms; }, request: async (op, _body, timeout) => {
    if (op === "prepare") { now += 600; return { state: "pending" }; }
    attempts++;
    now += timeout;
    throw new Error("timed out");
  } });
  expect(await client.call("memory_save", finding)).toMatchObject({ error: { code: "UNKNOWN_OUTCOME" } });
  expect(now).toBeLessThanOrEqual(2_000);
  expect(attempts).toBeLessThanOrEqual(3);
});

test("new model invocations get distinct keys and recovery never supplies identity itself", async () => {
  let key = 0;
  const keys: unknown[] = [];
  const calls: Record<string, unknown>[] = [];
  const client = new MemoryMcpClient({ operationKey: () => `key-${++key}`, request: async (op, body) => {
    calls.push(body);
    if (op === "prepare") { keys.push(body.operation_key); return { state: "pending" }; }
    return { outcome: "saved", id: "one" };
  } });
  await client.call("memory_save", finding);
  await client.call("memory_save", finding);
  await client.recover();
  expect(keys).toEqual(["key-1", "key-2"]);
  expect(calls.at(-1)).toEqual({});
});

test("forget timeouts are unknown outcomes and are not retried automatically", async () => {
  let calls = 0;
  const client = new MemoryMcpClient({ request: async () => { calls++; throw new Error("lost response"); } });
  expect(await client.call("memory_forget", { id: "memory" })).toMatchObject({ error: { code: "UNKNOWN_OUTCOME" } });
  expect(calls).toBe(1);
});

test("credential-shaped values are redacted before durable preparation and transport", async () => {
  const sent: string[] = [];
  const client = new MemoryMcpClient({ request: async (op, body) => {
    sent.push(JSON.stringify(body));
    return op === "prepare" ? { state: "pending" } : { id: "safe", outcome: "saved" };
  } });
  await client.call("memory_save", { ...finding, content: "The fixture password=do-not-retain was rejected", evidence: ["https://user:password@example.test/source"] });
  expect(sent).toHaveLength(2);
  expect(sent.every(body => body.includes("[REDACTED]") && !body.includes("do-not-retain") && !body.includes("user:password"))).toBe(true);
});

test("a forgotten prepared operation is never dispatched", async () => {
  const ops: string[] = [];
  const client = new MemoryMcpClient({ request: async op => { ops.push(op); return { state: "suppressed" }; } });
  expect(await client.call("memory_save", finding)).toMatchObject({ error: { code: "FORGOTTEN" } });
  expect(ops).toEqual(["prepare"]);
});

test("unadvertised and inherited object names cannot dispatch memory routes", async () => {
  let calls = 0;
  const client = new MemoryMcpClient({ request: async () => { calls++; return {}; } });
  for (const name of ["__proto__", "constructor", "toString", "memory_export"]) {
    expect(await client.call(name, {})).toMatchObject({ error: { code: "INVALID_ARGUMENT" } });
  }
  expect(calls).toBe(0);
});

test("a refusal after a lost save response does not imply the earlier commit was absent", async () => {
  for (const code of ["PAUSED", "FORBIDDEN", "CONFLICT", "NOT_A_SESSION"]) {
    let saves = 0;
    const client = new MemoryMcpClient({ sleep: async () => {}, operationKey: () => "uncertain-key", request: async op => {
      if (op === "prepare") return { state: "pending" };
      if (++saves === 1) throw new Error("committed but response lost");
      return { error: { code, message: "Current caller cannot retry" } };
    } });
    expect(await client.call("memory_save", finding)).toMatchObject({
      error: { code: "UNKNOWN_OUTCOME" }, operation_key: "uncertain-key", current_refusal: { code },
    });
    expect(saves).toBe(2);
  }
});

test("a refusal after a lost prepare response preserves queue uncertainty", async () => {
  let prepares = 0;
  const client = new MemoryMcpClient({ sleep: async () => {}, request: async op => {
    expect(op).toBe("prepare");
    if (++prepares === 1) throw new Error("prepared but response lost");
    return { error: { code: "PAUSED", message: "Paused after preparation" } };
  } });
  expect(await client.call("memory_save", finding)).toMatchObject({ error: { code: "UNKNOWN_OUTCOME" }, current_refusal: { code: "PAUSED" } });
});
