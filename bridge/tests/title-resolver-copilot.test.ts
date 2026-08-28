import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  resolveCopilotSessionTitle,
  copilotSessionExistsSync,
} from "../src/agents/github-copilot/title";
import { resolveStructuredTitle } from "../src/agents/title-dispatch";

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
