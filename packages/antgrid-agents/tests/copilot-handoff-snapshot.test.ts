import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { safeJoin } from "../src/agents/handoff";
import { copilotFork } from "../src/agents/github-copilot/fork";
import { withEnv } from "./fixtures/with-env";

const ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
let root: string;
let home: string;
let out: string;
let session: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "copilot-snap-"));
  home = join(root, "copilot");
  out = join(root, "out");
  session = join(home, "session-state", ID);
  mkdirSync(session, { recursive: true });
  mkdirSync(out);
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

const start = (id = ID) => JSON.stringify({ type: "session.start", data: { sessionId: id } });

function opts(extra: Record<string, unknown> = {}) {
  return {
    maxMsgs: 10,
    projectPath: join(root, "project"),
    sourceCwd: join(root, "project"),
    outDir: out,
    signal: new AbortController().signal,
    copilotHome: home,
    agentSessionId: ID,
    ...extra,
  };
}

test("copies events, workspace.yaml, checkpoints and files under flat indexed names; skips rewind snapshots", async () => {
  writeFileSync(join(session, "events.jsonl"), `${start()}\n{"type":"user.message"}\n{"torn":`);
  writeFileSync(join(session, "workspace.yaml"), "id: x\n");
  mkdirSync(join(session, "checkpoints"));
  writeFileSync(join(session, "checkpoints", "index.md"), "# index\n");
  writeFileSync(join(session, "checkpoints", "001-first.md"), "# first\n");
  mkdirSync(join(session, "files"));
  writeFileSync(join(session, "files", "Pasted Text.txt"), "pasted");
  writeFileSync(join(session, "files", "blob.bin"), Buffer.from([1, 0, 2]));
  mkdirSync(join(session, "rewind-file-snapshots"));
  writeFileSync(join(session, "rewind-file-snapshots", "tracking.json"), "{}");

  const snapshot = await copilotFork.snapshot(opts());
  expect(snapshot?.primary).toBe("copilot-events.jsonl");
  expect(snapshot?.files.map((f) => f.name)).toEqual([
    "copilot-events.jsonl",
    "copilot-workspace.yaml",
    "copilot-checkpoint-01.md",
    "copilot-checkpoint-02.md",
    "copilot-file-01",
  ]);
  expect(snapshot?.files.find((f) => f.name === "copilot-file-01")?.originalName).toBe("Pasted Text.txt");
  expect(snapshot?.references.map((r) => r.path.split(/[\\/]/).pop())).toEqual(["blob.bin"]);
  expect(readFileSync(join(out, "copilot-events.jsonl"), "utf8")).toBe(`${start()}\n{"type":"user.message"}\n`);
  expect(readFileSync(join(out, "copilot-file-01"), "utf8")).toBe("pasted");
  expect(existsSync(join(out, "tracking.json"))).toBe(false);
  for (const file of snapshot!.files) expect(() => safeJoin(out, file.name)).not.toThrow();
});

test("refuses a file whose session.start names another id", async () => {
  writeFileSync(join(session, "events.jsonl"), `${start("someone-else")}\n`);
  expect(await copilotFork.snapshot(opts())).toBeUndefined();
});

test("returns undefined before the first prompt, for a non-uuid id, and with no seam under test", async () => {
  expect(await copilotFork.snapshot(opts())).toBeUndefined();
  expect(await copilotFork.snapshot(opts({ agentSessionId: "../../etc" }))).toBeUndefined();
  writeFileSync(join(session, "events.jsonl"), `${start()}\n`);
  expect(await withEnv("COPILOT_HOME", home, () => copilotFork.snapshot(opts({ copilotHome: undefined })))).toBeUndefined();
  expect(await copilotFork.snapshot(opts())).toBeDefined();
});
