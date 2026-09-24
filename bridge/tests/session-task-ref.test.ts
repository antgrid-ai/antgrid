import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TaskRefSchema, createMessage, parseMessage } from "../src/protocol";
import { SessionManager } from "../src/session-manager";

const DART_TASK_REF = "app/lib/models/task_ref.dart";
const DART_SESSION_ENTRY = "app/lib/models/session_entry.dart";

function readRepoFile(relative: string): string {
  return readFileSync(join(import.meta.dir, "../..", relative), "utf8");
}

/**
 * The keys of the Dart mirror's `toJson()` map literal. `className` anchors the
 * search: a file holding more than one model would otherwise be read from the
 * first class in it, and pass or fail on the wrong one.
 */
function dartJsonKeys(source: string, className?: string): Set<string> {
  const from = className ? source.indexOf(`class ${className} {`) : 0;
  if (from < 0) throw new Error(`class ${className} not found in the Dart mirror`);
  const marker = "Map<String, dynamic> toJson() => {";
  const start = source.indexOf(marker, from);
  if (start < 0) throw new Error(`${marker} not found in the Dart mirror`);
  const end = source.indexOf("};", start);
  if (end < 0) throw new Error(`${marker} has no closing brace in the Dart mirror`);
  return new Set(
    [...source.slice(start + marker.length, end).matchAll(/'([^']+)'\s*:/g)].map((m) => m[1]!),
  );
}

function makeFakeTerm() {
  const spawned = new Set<string>();
  return {
    spawn: (cfg: { terminalId?: string }) => { spawned.add(cfg.terminalId!); return cfg.terminalId!; },
    kill: (id: string) => { spawned.delete(id); },
    has: (id: string) => spawned.has(id),
  };
}

function seed(storeDir: string, projectId: string, sessions: unknown[]): void {
  const dir = join(storeDir, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "sessions.json"), JSON.stringify({ version: 1, sessions }));
}

describe("taskRef on the session wire", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-task-ref-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  function manager(): SessionManager {
    return new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir,
      terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
  }

  it("parses session:create with and without a taskRef", () => {
    const withRef = parseMessage(JSON.stringify(createMessage("session:create", {
      requestId: "r1", name: "ANT-14 flaky test",
      taskRef: { taskId: "0f1e2d3c", number: 14 },
    })));
    expect(withRef?.type).toBe("session:create");
    expect(withRef?.type === "session:create" ? withRef.taskRef : undefined)
      .toEqual({ taskId: "0f1e2d3c", number: 14 });

    const without = parseMessage(JSON.stringify(createMessage("session:create", { requestId: "r2" })));
    expect(without?.type).toBe("session:create");
    expect(without?.type === "session:create" ? without.taskRef : "absent").toBeUndefined();
  });

  it("rejects a half-formed taskRef rather than carrying an unlabellable ref", () => {
    for (const taskRef of [
      { taskId: "", number: 14 },
      { taskId: "t1", number: 1.5 },
      { taskId: "t1" },
      { number: 14 },
    ]) {
      const raw = JSON.stringify(createMessage("session:create", { requestId: "r", taskRef } as never));
      expect(parseMessage(raw)).toBeNull();
    }
  });

  it("carries a taskRef from create through list, get and the session:updated frame", () => {
    const sm = manager();
    const created = sm.create(undefined, { taskRef: { taskId: "task-abc", number: 14 } });
    expect(created.taskRef).toEqual({ taskId: "task-abc", number: 14 });
    expect(sm.get(created.id)?.taskRef).toEqual({ taskId: "task-abc", number: 14 });
    expect(sm.list()[0]!.taskRef).toEqual({ taskId: "task-abc", number: 14 });

    // The frame agent-core emits from onChange, round-tripped through the wire
    // schema so a field the entry holds but the schema strips cannot pass.
    const updated = parseMessage(JSON.stringify(
      createMessage("session:updated", { sessions: sm.list(true) }),
    ));
    expect(updated?.type).toBe("session:updated");
    const entry = updated?.type === "session:updated" ? updated.sessions[0] : undefined;
    expect(entry?.taskRef).toEqual({ taskId: "task-abc", number: 14 });

    const listed = parseMessage(JSON.stringify(
      createMessage("session:list:result", { requestId: "r1", sessions: sm.list() }),
    ));
    expect(listed?.type === "session:list:result" ? listed.sessions[0]?.taskRef : undefined)
      .toEqual({ taskId: "task-abc", number: 14 });
  });

  it("keeps the taskRef across a host restart", async () => {
    const sm = manager();
    const created = sm.create(undefined, { taskRef: { taskId: "task-abc", number: 14 } });
    sm.flushNow();

    expect(manager().get(created.id)?.taskRef).toEqual({ taskId: "task-abc", number: 14 });
    const peeked = await SessionManager.readPersisted(dir, "p1");
    expect(peeked[0]!.taskRef).toEqual({ taskId: "task-abc", number: 14 });
  });

  it("creates without a taskRef when none was asked for", () => {
    const sm = manager();
    const created = sm.create();
    expect(created.taskRef).toBeUndefined();
    expect(JSON.parse(JSON.stringify(created))).not.toHaveProperty("taskRef");
  });

  it("reads a row written before the field existed", async () => {
    seed(dir, "p1", [{ id: "old", name: "Session 1", createdAt: 1, lastUsedAt: 2, archived: false }]);
    expect(manager().get("old")?.taskRef).toBeUndefined();
    expect((await SessionManager.readPersisted(dir, "p1"))[0]!.taskRef).toBeUndefined();
  });

  it("drops a malformed persisted taskRef without dropping the session", async () => {
    seed(dir, "p1", [{
      id: "bad", name: "Session 1", createdAt: 1, lastUsedAt: 2, archived: false,
      taskRef: { taskId: "task-abc" },
    }]);
    const entry = manager().get("bad");
    expect(entry).toBeDefined();
    expect(entry?.taskRef).toBeUndefined();
    expect((await SessionManager.readPersisted(dir, "p1"))[0]!.taskRef).toBeUndefined();
  });
});

// The cross-language half, in the BRIDGE workspace on purpose: the only
// workflow that runs `flutter test` is path-filtered to `app/**`, so a
// bridge-only PR renaming a taskRef field would ship drift with a green
// required check. The app carries a task label off this ref alone, so a rename
// on one side reaches the user as a session that lost its task.
describe("taskRef mirror contract", () => {
  it("the Dart scraper reads a toJson literal and nothing around it", () => {
    const fixture = `
      class Other { Map<String, dynamic> ignored() => {'nope': 1}; }
      Map<String, dynamic> toJson() => {'alpha': alpha, 'beta': beta};
      int get after => 0;
    `;
    expect([...dartJsonKeys(fixture)].sort()).toEqual(["alpha", "beta"]);

    const twoModels = `
      class First { Map<String, dynamic> toJson() => {'a': a}; }
      class Second { Map<String, dynamic> toJson() => {'b': b}; }
    `;
    expect([...dartJsonKeys(twoModels, "Second")]).toEqual(["b"]);
  });

  it("the Dart TaskRef carries exactly the schema's fields", () => {
    expect([...dartJsonKeys(readRepoFile(DART_TASK_REF), "TaskRef")].sort())
      .toEqual(Object.keys(TaskRefSchema.shape).sort());
  });

  it("the Dart SessionEntry serializes the ref under the wire's own key", () => {
    expect(dartJsonKeys(readRepoFile(DART_SESSION_ENTRY), "SessionEntry")).toContain("taskRef");
  });
});
