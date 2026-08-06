import { describe, it, expect } from "bun:test";
import { claudeResumeReplay } from "../src/agents/claude-code/resume-replay";

describe("claudeResumeReplay", () => {
  it("replays assistant text history as one resumed turn", () => {
    const msgs = claudeResumeReplay("s1", [
      { type: "user", message: { role: "user", content: "hi" } },
      { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "hello" }] }, uuid: "u1" },
    ]);
    expect(msgs.some((m) => m.type === "agent:turn-start")).toBe(true);
    const added = msgs.find((m) => m.type === "agent:item-added" && m.item.role === "assistant");
    expect(added).toBeDefined();
    if (added?.type === "agent:item-added") expect(added.item.text).toBe("hello");
    expect(msgs.some((m) => m.type === "agent:turn-end")).toBe(true);
  });

  it("stamps each frame with the entry's original ISO timestamp, not the replay moment", () => {
    const userTs = "2026-07-07T04:20:45.933Z";
    const asstTs = "2026-07-07T04:20:48.778Z";
    const msgs = claudeResumeReplay("s1", [
      { type: "user", message: { role: "user", content: "hi" }, uuid: "u1", timestamp: userTs },
      { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "hello" }] }, uuid: "a1", timestamp: asstTs },
    ]);
    const user = msgs.find((m) => m.type === "agent:item-added" && m.item.role === "user");
    const asst = msgs.find((m) => m.type === "agent:item-added" && m.item.role === "assistant");
    expect(user?.timestamp).toBe(Date.parse(userTs));
    expect(asst?.timestamp).toBe(Date.parse(asstTs));
    // turn-start takes the earliest entry time, turn-end the latest.
    expect(msgs.find((m) => m.type === "agent:turn-start")?.timestamp).toBe(Date.parse(userTs));
    expect(msgs.find((m) => m.type === "agent:turn-end")?.timestamp).toBe(Date.parse(asstTs));
  });

  it("leaves the createMessage timestamp intact when an entry has none", () => {
    const before = Date.now();
    const msgs = claudeResumeReplay("s1", [
      { type: "user", message: { role: "user", content: "hi" } },
    ]);
    const user = msgs.find((m) => m.type === "agent:item-added");
    // No source timestamp -> falls back to createMessage's Date.now() (~now).
    expect(user?.timestamp).toBeGreaterThanOrEqual(before);
  });
});

describe("claudeResumeReplay turn segmentation", () => {
  // The app folds a settled turn down to its user prompt + trailing answer
  // (deriveRows). One turn per prompt keeps each exchange's answer visible;
  // bundling the whole conversation into a single turn hid every assistant
  // message behind one fold row.
  const turnOf = (m: any) => m.turnId;

  it("opens one turn per user prompt, closing the previous", () => {
    const out = claudeResumeReplay("s1", [
      { type: "user", uuid: "u1", message: { role: "user", content: "first" } },
      { type: "assistant", uuid: "a1", message: { role: "assistant", content: [{ type: "text", text: "answer one" }] } },
      { type: "user", uuid: "u2", message: { role: "user", content: "second" } },
      { type: "assistant", uuid: "a2", message: { role: "assistant", content: [{ type: "text", text: "answer two" }] } },
    ]);
    const starts = out.filter((m) => m.type === "agent:turn-start");
    const ends = out.filter((m) => m.type === "agent:turn-end");
    expect(starts.length).toBe(2);
    expect(ends.length).toBe(2);
    // Distinct ids, and every frame between a start and its end shares that id.
    const ids = starts.map(turnOf);
    expect(new Set(ids).size).toBe(2);
    const first = out.filter((m: any) => turnOf(m) === ids[0]);
    expect(first.some((m: any) => m.item?.text === "answer one")).toBe(true);
    expect(first.some((m: any) => m.item?.text === "answer two")).toBe(false);
    // Each turn is closed before the next opens.
    expect(out.findIndex((m) => m.type === "agent:turn-end")).toBeLessThan(
      out.findLastIndex((m) => m.type === "agent:turn-start"),
    );
  });

  it("keeps a tool call in its prompt's turn", () => {
    const out = claudeResumeReplay("s1", [
      { type: "user", uuid: "u1", message: { role: "user", content: "read it" } },
      { type: "assistant", uuid: "a1", message: { role: "assistant", content: [{ type: "tool_use", id: "t1", name: "Read", input: {} }] } },
      { type: "user", uuid: "u2", message: { role: "user", content: "next" } },
    ]);
    const tool = out.find((m: any) => m.itemId === "tool:t1") as any;
    const firstStart = out.find((m) => m.type === "agent:turn-start") as any;
    expect(tool.turnId).toBe(firstStart.turnId);
  });

  it("puts history before the first user prompt in its own leading turn", () => {
    const out = claudeResumeReplay("s1", [
      { type: "assistant", uuid: "a0", message: { role: "assistant", content: [{ type: "text", text: "orphan" }] } },
      { type: "user", uuid: "u1", message: { role: "user", content: "hi" } },
    ]);
    expect(out.filter((m) => m.type === "agent:turn-start").length).toBe(2);
    const orphan = out.find((m: any) => m.item?.text === "orphan") as any;
    const firstStart = out.find((m) => m.type === "agent:turn-start") as any;
    expect(orphan.turnId).toBe(firstStart.turnId);
  });

  it("stamps each turn's start/end from its own entries", () => {
    const t0 = "2026-07-07T04:20:45.000Z";
    const t1 = "2026-07-07T04:20:48.000Z";
    const t2 = "2026-07-07T05:00:00.000Z";
    const t3 = "2026-07-07T05:00:09.000Z";
    const out = claudeResumeReplay("s1", [
      { type: "user", uuid: "u1", timestamp: t0, message: { role: "user", content: "a" } },
      { type: "assistant", uuid: "a1", timestamp: t1, message: { role: "assistant", content: [{ type: "text", text: "x" }] } },
      { type: "user", uuid: "u2", timestamp: t2, message: { role: "user", content: "b" } },
      { type: "assistant", uuid: "a2", timestamp: t3, message: { role: "assistant", content: [{ type: "text", text: "y" }] } },
    ]);
    const starts = out.filter((m) => m.type === "agent:turn-start");
    const ends = out.filter((m) => m.type === "agent:turn-end");
    expect(starts[0]?.timestamp).toBe(Date.parse(t0));
    expect(ends[0]?.timestamp).toBe(Date.parse(t1));
    expect(starts[1]?.timestamp).toBe(Date.parse(t2));
    expect(ends[1]?.timestamp).toBe(Date.parse(t3));
  });

  it("emits nothing for empty history", () => {
    expect(claudeResumeReplay("s1", [])).toEqual([]);
  });

  // Claude writes a prompt as a plain string OR as content blocks (attachments,
  // images). Both are prompts and both must open a turn — segmenting only on the
  // string shape collapsed an array-shaped exchange back into the previous turn.
  it("opens a turn for an array-content prompt and renders its text", () => {
    const out = claudeResumeReplay("s1", [
      { type: "user", uuid: "u1", message: { role: "user", content: "prompt one" } },
      { type: "assistant", uuid: "a1", message: { role: "assistant", content: [{ type: "text", text: "ans one" }] } },
      { type: "user", uuid: "u2", message: { role: "user", content: [{ type: "text", text: "prompt two" }] } },
      { type: "assistant", uuid: "a2", message: { role: "assistant", content: [{ type: "text", text: "ans two" }] } },
    ]);
    expect(out.filter((m) => m.type === "agent:turn-start").length).toBe(2);
    expect(out.some((m: any) => m.item?.text === "prompt two")).toBe(true);
    const one = out.find((m: any) => m.item?.text === "ans one") as any;
    const two = out.find((m: any) => m.item?.text === "ans two") as any;
    expect(one.turnId).not.toBe(two.turnId);
  });

  it("does not mistake a tool_result entry for a prompt", () => {
    // tool_result rides on a type:"user" entry with array content; it is the
    // agent's own tool output, so it must not open a turn.
    const out = claudeResumeReplay("s1", [
      { type: "user", uuid: "u1", message: { role: "user", content: "go" } },
      { type: "assistant", uuid: "a1", message: { role: "assistant", content: [{ type: "tool_use", id: "t1", name: "Read", input: {} }] } },
      { type: "user", uuid: "u2", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "file body" }] } },
      { type: "assistant", uuid: "a2", message: { role: "assistant", content: [{ type: "text", text: "done" }] } },
    ]);
    expect(out.filter((m) => m.type === "agent:turn-start").length).toBe(1);
    expect(out.some((m: any) => m.item?.text === "file body")).toBe(false);
  });

  it("segments on a text-less prompt without emitting a blank message row", () => {
    // An image-only prompt still starts an exchange; it just has nothing to render.
    const out = claudeResumeReplay("s1", [
      { type: "user", uuid: "u1", message: { role: "user", content: "first" } },
      { type: "assistant", uuid: "a1", message: { role: "assistant", content: [{ type: "text", text: "ans one" }] } },
      { type: "user", uuid: "u2", message: { role: "user", content: [{ type: "image", source: {} }] } },
      { type: "assistant", uuid: "a2", message: { role: "assistant", content: [{ type: "text", text: "ans two" }] } },
    ]);
    expect(out.filter((m) => m.type === "agent:turn-start").length).toBe(2);
    // No empty user item.
    expect(out.some((m: any) => m.item?.role === "user" && !m.item?.text)).toBe(false);
  });
});

describe("claudeResumeReplay usage backfill", () => {
  const usage = { input_tokens: 2, output_tokens: 300, cache_read_input_tokens: 28000, cache_creation_input_tokens: 3000 };

  it("emits one itemId-anchored agent:usage frame per assistant API message", () => {
    const out = claudeResumeReplay("s1", [
      { type: "user", message: { role: "user", content: "hi" }, uuid: "u1" },
      { type: "assistant", uuid: "a1", message: { id: "api-1", role: "assistant", usage, content: [{ type: "text", text: "hello" }] } },
    ]);
    const frames = out.filter((m: any) => m.type === "agent:usage") as any[];
    expect(frames.length).toBe(1);
    expect(frames[0].itemId).toBe("msg:a1");
    expect(frames[0].last.outputTokens).toBe(300);
    expect(frames[0].last.cacheReadTokens).toBe(28000);
    expect(frames[0].total).toEqual({});
    const anchorIdx = out.findIndex((m: any) => m.type === "agent:item-added" && m.itemId === "msg:a1");
    expect(out.indexOf(frames[0])).toBe(anchorIdx + 1);
  });

  it("dedups multiple JSONL lines sharing one message.id (one frame, anchored to the text line)", () => {
    const out = claudeResumeReplay("s1", [
      { type: "assistant", uuid: "a1", message: { id: "api-1", role: "assistant", usage, content: [{ type: "tool_use", id: "t1", name: "Read", input: {} }] } },
      { type: "assistant", uuid: "a2", message: { id: "api-1", role: "assistant", usage, content: [{ type: "text", text: "done" }] } },
      { type: "assistant", uuid: "a3", message: { id: "api-1", role: "assistant", usage, content: [{ type: "tool_use", id: "t2", name: "Edit", input: {} }] } },
    ]);
    const frames = out.filter((m: any) => m.type === "agent:usage") as any[];
    expect(frames.length).toBe(1);
    expect(frames[0].itemId).toBe("msg:a2");
  });

  it("emits no frame for tool-only messages or entries without usage", () => {
    const out = claudeResumeReplay("s1", [
      { type: "assistant", uuid: "a1", message: { id: "api-1", role: "assistant", usage, content: [{ type: "tool_use", id: "t1", name: "Read", input: {} }] } },
      { type: "assistant", uuid: "a2", message: { role: "assistant", content: [{ type: "text", text: "no usage here" }] } },
    ]);
    expect(out.filter((m: any) => m.type === "agent:usage").length).toBe(0);
  });
});
