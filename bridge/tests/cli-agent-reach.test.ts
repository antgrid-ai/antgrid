import { afterEach, describe, expect, test } from "bun:test";
import { runAgentReachCli } from "../src/cli/agent-reach";
import { GRANTS_OK, fakeHost } from "./cli-reach-support";

let host: ReturnType<typeof fakeHost> | undefined;
afterEach(() => host?.restore());

describe("antgrid agent-reach", () => {
  test("messages and control are no longer actions", async () => {
    host = fakeHost({});
    for (const action of ["messages", "control", "loud"]) {
      expect(await runAgentReachCli(action)).toBe(1);
    }
    expect(host.verbs).toEqual([]);
    expect(host.err.join("\n")).toContain("use on, off or status");
  });

  test("off sets reach off and touches no grant", async () => {
    host = fakeHost({ "agent-reach:set": { ok: true } });
    expect(await runAgentReachCli("off")).toBe(0);
    expect(host.verbs.map((v) => v.type)).toEqual(["agent-reach:set"]);
    expect(host.verbs[0]?.enabled).toBe(false);
  });

  test("on sets reach on and touches no grant", async () => {
    host = fakeHost({ "agent-reach:set": { ok: true } });
    expect(await runAgentReachCli("on")).toBe(0);
    expect(host.verbs.map((v) => v.type)).toEqual(["agent-reach:set"]);
    expect(host.verbs[0]?.enabled).toBe(true);
  });

  test("a failed set exits non-zero", async () => {
    host = fakeHost({ "agent-reach:set": { ok: false, error: { message: "refused" } } });
    expect(await runAgentReachCli("off")).toBe(1);
  });

  test("status is the default and prints agent reach and the orchestrator grant", async () => {
    host = fakeHost({ "bus-grants:get": GRANTS_OK });
    expect(await runAgentReachCli(undefined)).toBe(0);
    expect(host.out).toEqual(["agent reach: on", "orchestrator: on"]);
  });

  test("an unreachable host says it must be running", async () => {
    host = fakeHost({ "bus-grants:get": "throw" });
    expect(await runAgentReachCli("status")).toBe(1);
    expect(host.err.join("\n")).toContain("must be running");
  });
});
