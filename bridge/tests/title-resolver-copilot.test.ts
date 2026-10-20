import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  resolveCopilotSessionTitle,
  copilotSessionExistsSync,
} from "../../packages/antgrid-agents/src/agents/github-copilot/title";
import { resolveStructuredTitle } from "../../packages/antgrid-agents/src/agents/title-dispatch";

const dirs: string[] = [];

function tmp() {
  const d = mkdtempSync(join(tmpdir(), "ab-copilot-"));
  dirs.push(d);
  return d;
}

afterEach(() => {
  for (const d of dirs.splice(0)) {
    try {
      rmSync(d, { recursive: true, force: true });
    } catch {}
  }
});

/** Seed a session-store.db matching copilot's real schema for the columns we read. */
function seed(
  home: string,
  sessions: Array<{ id: string; summary?: string | null }>,
  turns: Array<{ session_id: string; turn_index: number; user_message?: string | null }> = [],
) {
  const db = new Database(join(home, "session-store.db"));
  db.run("CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT, branch TEXT, summary TEXT, created_at TEXT, updated_at TEXT)");
  db.run("CREATE TABLE turns (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, turn_index INTEGER, user_message TEXT, assistant_response TEXT, timestamp TEXT)");
  const si = db.query("INSERT INTO sessions (id, summary) VALUES (?, ?)");
  for (const s of sessions) si.run(s.id, s.summary ?? null);
  const ti = db.query("INSERT INTO turns (session_id, turn_index, user_message) VALUES (?, ?, ?)");
  for (const t of turns) ti.run(t.session_id, t.turn_index, t.user_message ?? null);
  db.close();
}

describe("resolveCopilotSessionTitle", () => {
  test("ignores Copilot's own summary and reports the first user turn", async () => {
    const home = tmp();
    seed(home, [{ id: "sess-1", summary: "Fix the parser" }], [
      { session_id: "sess-1", turn_index: 0, user_message: "the parser drops semicolons" },
    ]);
    // We name sessions ourselves, so Copilot's summary is not a title source —
    // depending on it meant a session got a name only once Copilot wrote one.
    expect(await resolveCopilotSessionTitle("sess-1", home))
      .toEqual({ title: "the parser drops semicolons", kind: "first-message" });
  });

  test("reports the first-turn user_message", async () => {
    const home = tmp();
    seed(home, [{ id: "sess-2", summary: null }], [
      { session_id: "sess-2", turn_index: 1, user_message: "second" },
      { session_id: "sess-2", turn_index: 0, user_message: "first message" },
    ]);
    expect(await resolveCopilotSessionTitle("sess-2", home)).toEqual({ title: "first message", kind: "first-message" });
  });

  test("falls back to the first non-empty trimmed user_message", async () => {
    const home = tmp();
    seed(home, [{ id: "sess-blank", summary: null }], [
      { session_id: "sess-blank", turn_index: 0, user_message: null },
      { session_id: "sess-blank", turn_index: 1, user_message: "" },
      { session_id: "sess-blank", turn_index: 2, user_message: "   " },
      { session_id: "sess-blank", turn_index: 3, user_message: "  real prompt  " },
    ]);
    expect(await resolveCopilotSessionTitle("sess-blank", home)).toEqual({ title: "real prompt", kind: "first-message" });
  });

  // The shape Copilot 1.0.83-1.0.95 leaves after one prompt: a sessions row,
  // no turns row (written only at the next prompt or at shutdown), and the
  // prompt in session-state/<id>/events.jsonl.
  function seedEvents(home: string, id: string, events: unknown[]) {
    const dir = join(home, "session-state", id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "events.jsonl"), events.map((e) => JSON.stringify(e)).join("\n") + "\n");
  }
  const ID = "0f2b6c1e-4d7a-4c55-9a31-2e8d6b0c7f14";
  const event = (type: string, data: object) =>
    ({ type, data, id: crypto.randomUUID(), timestamp: "2026-10-12T09:00:00.000Z", parentId: null });

  test("reads the first prompt from events.jsonl before Copilot writes its turns row", async () => {
    const home = tmp();
    seed(home, [{ id: ID, summary: null }]);
    seedEvents(home, ID, [
      event("session.start", { sessionId: ID, version: 1, producer: "copilot-agent", copilotVersion: "1.0.95", startTime: "2026-10-12T09:00:00.000Z", context: { cwd: "/work/demo" } }),
      event("session.model_change", { cause: "initial_resolution", source: "automatic", newModel: "auto" }),
      event("user.message", { content: "  rename the widget module  ", transformedContent: "<current_datetime>2026-10-12</current_datetime>\n\nrename the widget module", messageId: "m1", delivery: "idle", interactionId: "i1", turnId: "0" }),
      event("system.message", { role: "system", content: "You are the GitHub Copilot CLI." }),
      event("assistant.turn_start", { turnId: "0" }),
      event("user.message", { content: "second prompt", transformedContent: "second prompt", messageId: "m2", delivery: "idle", interactionId: "i2", turnId: "1" }),
    ]);
    expect(await resolveCopilotSessionTitle(ID, home)).toEqual({ title: "rename the widget module", kind: "first-message" });
  });

  test("prefers the turns row over events.jsonl", async () => {
    const home = tmp();
    seed(home, [{ id: ID, summary: null }], [{ session_id: ID, turn_index: 0, user_message: "from the store" }]);
    seedEvents(home, ID, [event("user.message", { content: "from the log", turnId: "0" })]);
    expect(await resolveCopilotSessionTitle(ID, home)).toEqual({ title: "from the store", kind: "first-message" });
  });

  test("null when neither the store nor the event log holds a prompt", async () => {
    const home = tmp();
    seed(home, [{ id: ID, summary: null }]);
    expect(await resolveCopilotSessionTitle(ID, home)).toBeNull();
    seedEvents(home, ID, [event("session.start", { sessionId: ID }), event("user.message", { content: "   " })]);
    expect(await resolveCopilotSessionTitle(ID, home)).toBeNull();
  });

  test("never builds an event-log path from a non-uuid session id", async () => {
    const home = tmp();
    const id = "../escape";
    seed(home, [{ id, summary: null }]);
    // Where session-state/../escape/events.jsonl would resolve to.
    mkdirSync(join(home, "escape"));
    writeFileSync(join(home, "escape", "events.jsonl"), JSON.stringify(event("user.message", { content: "outside" })) + "\n");
    expect(await resolveCopilotSessionTitle(id, home)).toBeNull();
  });

  test("returns null for a missing session id", async () => {
    const home = tmp();
    seed(home, [{ id: "sess-3", summary: "x" }]);
    expect(await resolveCopilotSessionTitle("nope", home)).toBeNull();
  });

  test("returns null when the db file is missing", async () => {
    expect(await resolveCopilotSessionTitle("any", join(tmp(), "no-such"))).toBeNull();
  });
});

describe("copilotSessionExistsSync", () => {
  test("true for an existing id, false for a missing id", () => {
    const home = tmp();
    seed(home, [{ id: "real", summary: null }]);
    expect(copilotSessionExistsSync("real", home)).toBe(true);
    expect(copilotSessionExistsSync("ghost", home)).toBe(false);
  });

  test("null when the db is missing", () => {
    expect(copilotSessionExistsSync("x", join(tmp(), "no-such"))).toBeNull();
  });
});

describe("resolveStructuredTitle -> github-copilot", () => {
  test("routes to the copilot reader via copilotHome", async () => {
    const home = tmp();
    seed(home, [{ id: "sess-9", summary: "Routed title" }], [
      { session_id: "sess-9", turn_index: 0, user_message: "routed message" },
    ]);
    const title = await resolveStructuredTitle("github-copilot", { sessionId: "sess-9" }, { copilotHome: home });
    expect(title).toEqual({ title: "routed message", kind: "first-message" });
  });
});
