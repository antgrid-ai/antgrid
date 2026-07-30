// bridge/tests/handler/brief.test.ts
import { describe, it, expect } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  BriefSchema, parseBriefFromOutput, buildPlanPrompt,
  loadHandlerSession, saveHandlerSession, renderLedger, remainingThenItems,
  type HandlerSessionRecord,
} from "../../src/handler/brief";

const BRIEF = {
  taskSummary: "Migrating auth module",
  willHandle: ["routine [Y/n] prompts"],
  wakeFor: ["schema changes"],
  doneWhen: "all tests in test/auth pass",
  thenItems: ["/compact", "run code-review skill and apply fixes"],
};

describe("BriefSchema", () => {
  it("accepts a full brief and one without doneWhen", () => {
    expect(BriefSchema.safeParse(BRIEF).success).toBe(true);
    const { doneWhen: _d, ...noDone } = BRIEF;
    expect(BriefSchema.safeParse(noDone).success).toBe(true);
  });
  it("rejects missing sections", () => {
    expect(BriefSchema.safeParse({ taskSummary: "x" }).success).toBe(false);
  });
});

describe("parseBriefFromOutput", () => {
  it("extracts the first JSON object from noisy stdout", () => {
    const out = `thinking...\n${JSON.stringify(BRIEF)}\ntrailing`;
    expect(parseBriefFromOutput(out)?.taskSummary).toBe("Migrating auth module");
  });
  it("returns null on invalid JSON or schema mismatch", () => {
    expect(parseBriefFromOutput("no json here")).toBeNull();
    expect(parseBriefFromOutput('{"taskSummary": 42}')).toBeNull();
  });
});

describe("buildPlanPrompt", () => {
  it("includes context and transcript pull-through only when a path is given", () => {
    const withPath = buildPlanPrompt("CTX", "/tmp/t.jsonl");
    expect(withPath).toContain("CTX");
    expect(withPath).toContain("/tmp/t.jsonl");
    expect(buildPlanPrompt("CTX")).not.toContain("Fuller transcript");
  });
});

describe("session record store", () => {
  it("round-trips and returns null for missing/corrupt files", () => {
    const abDir = mkdtempSync(join(tmpdir(), "ab-brief-"));
    const rec: HandlerSessionRecord = {
      version: 1, terminalId: "term-1", armed: true, brief: BRIEF,
      notifyOnly: false, armedAt: 123, doneWhenMet: false, ledger: [], escalations: [],
    };
    expect(loadHandlerSession(abDir, "proj", "term-1")).toBeNull();
    saveHandlerSession(abDir, "proj", rec);
    expect(loadHandlerSession(abDir, "proj", "term-1")?.brief.taskSummary)
      .toBe("Migrating auth module");
  });
});

describe("ledger rendering", () => {
  it("splits satisfied from remaining and renders evidence", () => {
    const ledger = [{ item: "/compact", evidence: "compact ran at turn 12", at: 1 }];
    expect(remainingThenItems(BRIEF, ledger))
      .toEqual(["run code-review skill and apply fixes"]);
    const text = renderLedger(BRIEF, ledger);
    expect(text).toContain("compact ran at turn 12");
    expect(text).toContain("run code-review skill and apply fixes");
  });
});

describe("session record judge fields", () => {
  it("session record round-trips judgeTool/judgeModel", () => {
    const abDir = mkdtempSync(join(tmpdir(), "ab-brief-"));
    const rec = {
      version: 1 as const, terminalId: "t1", armed: true,
      brief: { taskSummary: "x", willHandle: [], wakeFor: [], thenItems: [] },
      notifyOnly: false, armedAt: 1, doneWhenMet: false, ledger: [], escalations: [],
      judgeTool: "codex", judgeModel: "gpt-5.3-codex",
    };
    saveHandlerSession(abDir, "proj", rec);
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.judgeTool).toBe("codex");
    expect(loaded?.judgeModel).toBe("gpt-5.3-codex");
  });

  it("a record written before judge fields existed still parses", () => {
    const abDir = mkdtempSync(join(tmpdir(), "ab-brief-"));
    const rec = {
      version: 1 as const, terminalId: "t2", armed: true,
      brief: { taskSummary: "x", willHandle: [], wakeFor: [], thenItems: [] },
      notifyOnly: false, armedAt: 1, doneWhenMet: false, ledger: [], escalations: [],
    };
    saveHandlerSession(abDir, "proj", rec);
    const loaded = loadHandlerSession(abDir, "proj", "t2");
    expect(loaded).not.toBeNull();
    expect(loaded?.judgeTool).toBeUndefined();
  });
});
