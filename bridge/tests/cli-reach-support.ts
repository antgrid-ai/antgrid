import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spyOn } from "bun:test";
import { writeHostFile } from "../src/host-discovery";

type Scripted = { ok: boolean; [k: string]: unknown } | "throw";

/** Stands in for the host's loopback control plane: records each verb body and
 *  answers from a per-verb script, so the CLI's exit codes can be driven
 *  without a running host. */
export function fakeHost(script: Record<string, Scripted>) {
  const prev = process.env.ANTGRID_DIR;
  const dir = mkdtempSync(join(tmpdir(), "antgrid-reach-cli-"));
  writeHostFile(join(dir, "host.json"), {
    version: 1, pid: process.pid, controlPort: 4999, token: "t", startedAt: "x", agentVersion: "0",
  });
  process.env.ANTGRID_DIR = dir;
  const verbs: Array<Record<string, unknown>> = [];
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation((async (_u: unknown, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
    verbs.push(body);
    const answer = script[String(body.type)];
    if (answer === undefined || answer === "throw") throw new Error("Unable to connect");
    return new Response(JSON.stringify(answer), { status: 200 });
  }) as unknown as typeof fetch);
  const out: string[] = [];
  const err: string[] = [];
  const log = spyOn(console, "log").mockImplementation((...a: unknown[]) => { out.push(a.join(" ")); });
  const error = spyOn(console, "error").mockImplementation((...a: unknown[]) => { err.push(a.join(" ")); });
  return {
    verbs, out, err,
    restore() {
      fetchSpy.mockRestore(); log.mockRestore(); error.mockRestore();
      if (prev === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prev;
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

/** A failed web call, worded the way the host words it. */
export function webRefused(code: string) {
  return { ok: false, error: { code, message: `the account service refused the request (${code})` } };
}

export const GRANTS_OK = { ok: true, grants: { orchestrator: true, busControl: false }, reachEnabled: true, level: "messages" };
