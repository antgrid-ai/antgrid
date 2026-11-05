import { afterEach, describe, expect, test } from "bun:test";
import { runAgentReachCli } from "../src/cli/agent-reach";
import { GRANTS_OK, fakeHost, webRefused } from "./cli-reach-support";

let host: ReturnType<typeof fakeHost> | undefined;
afterEach(() => host?.restore());

const lowerFails = webRefused("WEB_503");

describe("antgrid agent-reach", () => {
  test("control is refused without contacting the host", async () => {
    host = fakeHost({});
    expect(await runAgentReachCli("control")).toBe(1);
    expect(host.verbs).toEqual([]);
    expect(host.err.join("\n")).toContain("app");
  });

  test("an unknown action exits non-zero without contacting the host", async () => {
    host = fakeHost({});
    expect(await runAgentReachCli("loud")).toBe(1);
    expect(host.verbs).toEqual([]);
  });

  test("off sets reach off then lowers bus control", async () => {
    host = fakeHost({ "agent-reach:set": { ok: true }, "bus-grants:lower": GRANTS_OK });
    expect(await runAgentReachCli("off")).toBe(0);
    expect(host.verbs.map((v) => v.type)).toEqual(["agent-reach:set", "bus-grants:lower"]);
    expect(host.verbs[0]?.enabled).toBe(false);
    expect(host.verbs[1]?.busControl).toBe(false);
    expect(host.verbs[1]).not.toHaveProperty("orchestrator");
  });

  test("messages sets reach on then lowers bus control", async () => {
    host = fakeHost({ "agent-reach:set": { ok: true }, "bus-grants:lower": GRANTS_OK });
    expect(await runAgentReachCli("messages")).toBe(0);
    expect(host.verbs.map((v) => v.type)).toEqual(["agent-reach:set", "bus-grants:lower"]);
    expect(host.verbs[0]?.enabled).toBe(true);
  });

  test("off still succeeds when only the lowering fails", async () => {
    host = fakeHost({ "agent-reach:set": { ok: true }, "bus-grants:lower": lowerFails });
    expect(await runAgentReachCli("off")).toBe(0);
    expect(host.err.join("\n")).toContain("local off already wins");
    expect(host.err.join("\n")).toContain("WEB_503");
  });

  test("messages fails when the lowering fails", async () => {
    host = fakeHost({ "agent-reach:set": { ok: true }, "bus-grants:lower": lowerFails });
    expect(await runAgentReachCli("messages")).toBe(1);
    expect(host.err.join("\n")).toContain("WEB_503");
  });

  test("a failed set does not attempt the lowering", async () => {
    host = fakeHost({ "agent-reach:set": { ok: false, error: { message: "refused" } } });
    expect(await runAgentReachCli("off")).toBe(1);
    expect(host.verbs).toHaveLength(1);
  });

  test("status is the default and prints the effective level and both grants", async () => {
    host = fakeHost({ "bus-grants:get": GRANTS_OK });
    expect(await runAgentReachCli(undefined)).toBe(0);
    expect(host.out).toEqual(["effective reach: messages", "orchestrator: on", "bus control: off"]);
  });

  test("status says when the account's grant has not reached the enforced level yet", async () => {
    host = fakeHost({ "bus-grants:get": { ...GRANTS_OK, grants: { orchestrator: false, busControl: true } } });
    expect(await runAgentReachCli("status")).toBe(0);
    expect(host.out[0]).toBe("effective reach: messages");
    expect(host.out.at(-1)).toContain("next directory refresh");
  });

  test("an unreachable host says it must be running", async () => {
    host = fakeHost({ "bus-grants:get": "throw" });
    expect(await runAgentReachCli("status")).toBe(1);
    expect(host.err.join("\n")).toContain("must be running");
  });
});
