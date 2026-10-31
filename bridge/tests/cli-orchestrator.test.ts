import { afterEach, describe, expect, test } from "bun:test";
import { runOrchestratorCli } from "../src/cli/orchestrator";
import { GRANTS_OK, fakeHost, webRefused } from "./cli-reach-support";

let host: ReturnType<typeof fakeHost> | undefined;
afterEach(() => host?.restore());

describe("antgrid orchestrator", () => {
  test("on is refused without contacting the host", async () => {
    host = fakeHost({});
    expect(await runOrchestratorCli("on")).toBe(1);
    expect(host.verbs).toEqual([]);
    expect(host.err.join("\n")).toContain("app");
  });

  test("an unknown action exits non-zero without contacting the host", async () => {
    host = fakeHost({});
    expect(await runOrchestratorCli("maybe")).toBe(1);
    expect(host.verbs).toEqual([]);
  });

  test("off lowers only the orchestrator grant", async () => {
    host = fakeHost({ "bus-grants:lower": GRANTS_OK });
    expect(await runOrchestratorCli("off")).toBe(0);
    expect(host.verbs).toHaveLength(1);
    expect(host.verbs[0]).toMatchObject({ type: "bus-grants:lower", orchestrator: false });
    expect(host.verbs[0]).not.toHaveProperty("busControl");
  });

  test("off exits non-zero when the lowering fails", async () => {
    host = fakeHost({ "bus-grants:lower": webRefused("WEB_403") });
    expect(await runOrchestratorCli("off")).toBe(1);
    expect(host.err.join("\n")).toContain("WEB_403");
  });

  test("status is the default and prints both grants", async () => {
    host = fakeHost({ "bus-grants:get": GRANTS_OK });
    expect(await runOrchestratorCli(undefined)).toBe(0);
    expect(host.verbs[0]?.type).toBe("bus-grants:get");
    expect(host.out).toContain("orchestrator: on");
  });
});
