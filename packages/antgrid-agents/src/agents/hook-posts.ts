// Primitives shared by every agent's hook profile. Kept out of hook-runner.ts so
// a per-agent hooks.ts can import them without closing a cycle back through the
// registry the runner dispatches on.

import { z } from "zod";

export type HookPath =
  | "/session-title"
  | "/notify"
  | "/handler-event"
  | "/turn-start"
  | "/turn-activity"
  | "/hook-alive";

export interface HookPost {
  port: number;
  path: HookPath;
  body: Record<string, unknown>;
}

export interface HookInvocation {
  agent: string;
  event: string;
  payload?: string;
}

function parseJson(raw: string): unknown {
  try {
    // Cursor really does prefix its hook stdin with a BOM; JSON.parse rejects it.
    return JSON.parse(raw.replace(/^\uFEFF/, ""));
  } catch {
    return {};
  }
}

/**
 * Rust/serde agents serialize an absent field as JSON `null`, so every optional
 * field in a hook payload schema is `.nullish()`; `.optional()` alone rejects
 * `null`, which fails the whole parse and silently drops every post for that
 * event.
 */
export function parseOrEmpty<T>(schema: z.ZodType<T>, raw: string): T | null {
  const parsed = schema.safeParse(parseJson(raw));
  return parsed.success ? parsed.data : null;
}

export function titlePost(
  port: number,
  terminalId: string | undefined,
  sessionId: string | null | undefined,
  agent: string,
  extra: Record<string, unknown> = {},
): HookPost | null {
  if (!terminalId || !sessionId) return null;
  return {
    port,
    path: "/session-title",
    body: { terminalId, sessionId, agent, ...extra },
  };
}

/** Drops the nulls a `titlePost` returns when it had no terminal or session id. */
export function compact(posts: Array<HookPost | null>): HookPost[] {
  return posts.filter((post): post is HookPost => post !== null);
}

// A submission the model can name a task from. A slash command is the user
// invoking a command, not describing what they want done — "/clear", "/commit"
// and their arguments name the command, so a title generated from one describes
// the tool rather than the session, and the attempt it spends is gone.
// Withholding `prompt` does not drop the post: it falls through to the on-disk
// read, which is what a session without a pre-turn hook already does. Shared by
// every agent whose turn-start hook carries the raw prompt text.
export function namesTheSession(prompt: string | null | undefined): boolean {
  const text = prompt?.trim();
  return !!text && !text.startsWith("/");
}
