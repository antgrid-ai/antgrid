// bridge/tests/handler/reply-shape.test.ts
import { describe, it, expect } from "bun:test";
import {
  MAX_REPLY_CHARS, checkReplyShape, findCommand, oneLine, replyShape, splitSlashCommand,
} from "../../src/handler/reply-shape";
import type { CapCommand } from "../../src/structured/chat-session";
import type { HandlerDecision } from "../../src/handler/decision";

function handle(over: Partial<HandlerDecision>): HandlerDecision {
  return { decision: "handle", confidence: 0.9, reason: "r", ...over } as HandlerDecision;
}
function slash(value: string): HandlerDecision {
  return handle({ action: { kind: "slash_command", value } });
}

describe("splitSlashCommand", () => {
  it("splits on the FIRST run of whitespace and keeps the tail's own spacing", () => {
    expect(splitSlashCommand("/review   src/a.ts src/b.ts"))
      .toEqual({ verb: "/review", args: "src/a.ts src/b.ts" });
  });
  it("a bare verb has no arguments", () => {
    expect(splitSlashCommand("/compact")).toEqual({ verb: "/compact", args: "" });
  });
  it("a trailing space is not an argument", () => {
    expect(splitSlashCommand("  /compact  ")).toEqual({ verb: "/compact", args: "" });
  });
});

describe("replyShape", () => {
  it("written is the action value flattened to one line", () => {
    // The whole line is submitted with a trailing CR, so a break anywhere inside it
    // would submit half a command and leave the rest as the next one.
    const shape = replyShape(slash("  /review  a.ts   b.ts "));
    expect(shape.written).toBe("/review a.ts b.ts");
    expect(shape.args).toBe("a.ts b.ts");
  });
  it("a line break in the argument tail is flattened, never refused", () => {
    const shape = replyShape(slash("/review a.ts\nb.ts"));
    expect(shape.written).toBe("/review a.ts b.ts");
    expect(shape.args).toBe("a.ts b.ts");
    expect(checkReplyShape(shape, undefined)).toBeNull();
  });
  it("a reply is flattened to the one line injectReply will submit", () => {
    expect(replyShape(handle({ reply: "line one\n\nline two" })).reply).toBe("line one line two");
  });
  it("an action of kind none contributes nothing", () => {
    const shape = replyShape(handle({ reply: "carry on", action: { kind: "none", value: "" } }));
    expect(shape.actionText).toBe("");
    expect(shape.written).toBe("carry on");
  });
});

describe("findCommand", () => {
  const catalog: CapCommand[] = [{ id: "cmd:code-review", name: "Code-Review" }];
  it("matches case-insensitively, ignoring the leading slash", () => {
    expect(findCommand(catalog, "/code-review")?.id).toBe("cmd:code-review");
  });
  it("returns undefined for an unknown verb, an empty verb and an absent catalog", () => {
    expect(findCommand(catalog, "/nope")).toBeUndefined();
    expect(findCommand(catalog, "")).toBeUndefined();
    expect(findCommand(undefined, "/code-review")).toBeUndefined();
  });
  it("never matches an id prefix — the id is per-backend routing metadata", () => {
    expect(findCommand([{ id: "cmd:review", name: "review" }], "/cmd")).toBeUndefined();
  });
});

describe("checkReplyShape", () => {
  const catalog: CapCommand[] = [{ id: "cmd:review", name: "review" }];

  it("an empty decision is rejected and is not worth re-asking", () => {
    expect(checkReplyShape(replyShape(handle({})), undefined))
      .toEqual({ reason: "empty reply", retryable: false });
  });

  it("setting both reply and action is a teachable judge error", () => {
    const shape = replyShape(handle({ reply: "carry on", action: { kind: "slash_command", value: "/compact" } }));
    expect(checkReplyShape(shape, undefined))
      .toEqual({ reason: "set either reply or action, not both", retryable: true });
  });

  it("an over-length reply is retryable", () => {
    const shape = replyShape(handle({ reply: "x".repeat(MAX_REPLY_CHARS + 1) }));
    expect(checkReplyShape(shape, undefined)?.retryable).toBe(true);
    expect(checkReplyShape(shape, undefined)?.reason).toContain("reply too long");
  });

  it("an over-length action value names the action field", () => {
    const r = checkReplyShape(replyShape(slash(`/review ${"x".repeat(MAX_REPLY_CHARS)}`)), undefined);
    expect(r?.retryable).toBe(true);
    expect(r?.reason).toContain("action.value too long");
  });

  it("a control char that is not whitespace is retryable", () => {
    expect(checkReplyShape(replyShape(handle({ reply: "pick two\x1b[B" })), undefined))
      .toEqual({ reason: "reply contains control characters", retryable: true });
  });

  it("a control char surviving the flatten is refused, and the reason names the action field", () => {
    // The pair with the reply case above is what proves the flatten collapsed only
    // whitespace: an escape sequence is still a keystroke and still fails the guard.
    expect(checkReplyShape(replyShape(slash("/review \x1b[B")), undefined))
      .toEqual({ reason: "action.value contains control characters", retryable: true });
  });

  it("a path-shaped verb is rejected even when it carries arguments", () => {
    const r = checkReplyShape(replyShape(slash("/etc/hosts --force")), undefined);
    expect(r?.retryable).toBe(true);
    expect(r?.reason).toContain("not a simple verb");
    // The reason is fed back to the judge verbatim, so it has to say where the prose
    // it crammed into `value` belongs instead.
    expect(r?.reason).toContain("`reason`");
  });

  it("a backslash in the verb is rejected too", () => {
    expect(checkReplyShape(replyShape(slash("/c\\windows")), undefined)?.retryable).toBe(true);
  });

  it("a verb outside a populated catalog is refused and is NOT worth re-asking", () => {
    const r = checkReplyShape(replyShape(slash("/invented")), catalog);
    expect(r?.retryable).toBe(false);
    expect(r?.reason).toContain("/invented");
  });

  it("a catalog member passes with its arguments attached", () => {
    expect(checkReplyShape(replyShape(slash("/review --fix src/a.ts")), catalog)).toBeNull();
  });

  it("an invented verb passes when no catalog is available", () => {
    // A PTY, a driver reporting none, discovery that has not landed: refusing here
    // would ground every terminal session on a catalog nobody can produce.
    expect(checkReplyShape(replyShape(slash("/invented arg")), undefined)).toBeNull();
  });

  it("an EMPTY catalog reads the same as an absent one", () => {
    // buildDecidePrompt renders the no-catalog sentence on `commands?.length`, so
    // refusing here would tell the judge no catalog exists and then reject every
    // command it emits against one.
    expect(checkReplyShape(replyShape(slash("/invented arg")), [])).toBeNull();
  });
});

describe("oneLine", () => {
  it("collapses every whitespace run and trims", () => {
    expect(oneLine("  a\n\n b\t c  ")).toBe("a b c");
  });
});
