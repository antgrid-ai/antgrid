/// <reference path="../../src/opencode-plugin.d.ts" />
// Antgrid opencode plugin: reports one opencode terminal to the bridge in the
// vocabulary the bridge's hook routes already speak — the turn's start
// (/turn-start, /turn-activity) and end (/notify + /handler-event turn_end), the
// permission/question blocks a turn stops on and their resolution, the live
// conversation title (/session-title), and the Handler's triggers. Runs inside
// opencode's own Bun runtime, so we use fetch (no node). Correlation via the
// ANTGRID_TERMINAL_ID env.
import type { Plugin } from "@opencode-ai/plugin";

// Posts go out one at a time (see `send`), so a bridge that accepts the
// connection and then hangs would hold up every post queued behind it; a dead
// bridge already fails fast with ECONNREFUSED. Every post below is disposable.
const BRIDGE_TIMEOUT_MS = 2000;

// The bridge decays a turn it has heard nothing about for 30 minutes. opencode
// republishes `busy` on every model step, so a throttled re-assert off those
// keeps one long run from reading "done" while it is still working.
const ACTIVITY_INTERVAL_MS = 60_000;

// Bounds the loopback POST, not the display — the same ceiling the Claude hook
// clips a question to.
const MAX_DETAIL_CHARS = 400;

type Post = { path: string; body: Record<string, unknown> };

function clip(text: unknown): string | undefined {
  if (typeof text !== "string") return undefined;
  const trimmed = text.trim();
  return trimmed ? trimmed.slice(0, MAX_DETAIL_CHARS) : undefined;
}

// A notification must still fire without a terminal id, just without a session
// name. Everything addressed to a slot cannot.
function notifyPost(terminalId: string | undefined, kind: string, message?: string): Post {
  return { path: "/notify", body: { type: kind, ...(terminalId ? { terminalId } : {}), ...(message ? { message } : {}) } };
}

function handlerPosts(terminalId: string | undefined, kind: string, extra: Record<string, unknown> = {}): Post[] {
  return terminalId ? [{ path: "/handler-event", body: { terminalId, agent: "opencode", event: kind, ...extra } }] : [];
}

// opencode's loader calls EVERY export of this module as a plugin and throws on
// one that is not a function, so nothing but the plugin itself may be exported.
export const AntgridSessionNamer: Plugin = async () => {
  // Per opencode instance, and only ever touched synchronously: opencode calls
  // the event handler in publish order but never awaits it, so every decision
  // is made before the first await and only the sends are deferred.
  //
  // Subagents run as sessions of their own. Their status says nothing about the
  // terminal — a child going idle while its parent works is not the turn ending
  // — so only root sessions drive the turn. A child is known from its
  // session.created/session.updated (`info.parentID`); opencode touches a
  // session, publishing session.updated, before every prompt into it, so a child
  // is always classified before its first `busy`.
  const children = new Set<string>();
  // Root sessions this plugin has seen go busy and not yet seen go idle.
  const working = new Set<string>();
  // A root session's own error, held until its run actually stops: opencode
  // reports a context overflow it is about to compact away as an error too,
  // and a run that keeps going has not failed.
  const failed = new Map<string, string | undefined>();
  // Prompts announced to the bridge and not yet retired, by request id → the
  // session that asked. Includes subagents' prompts: opencode's TUI shows a
  // child's permission or question in the parent's view, and the user has to
  // answer it there exactly like a root one.
  const prompts = new Map<string, string | undefined>();
  // True between a /turn-start this plugin posted and the closer that ends it.
  // Only a transition posts — `busy` repeats on every model step and `retry` →
  // `busy` within one run — and every close resets it, so each opened turn has
  // exactly one closer and a later `busy` opens the next.
  let turnOpen = false;
  let lastAssertAt = 0;
  // An opencode too old to publish session.status still publishes session.idle;
  // until a status is seen, that is the only turn-end signal there is.
  let sawStatus = false;

  // Sends strictly in event order, each after the previous one's response.
  // Without this a short run's /turn-start and /notify idle race each other to
  // the bridge, and an open that lands after its own close is a turn nothing
  // will ever end.
  let chain: Promise<void> = Promise.resolve();
  const send = (port: string, runId: string | undefined, posts: Post[]): Promise<void> => {
    if (posts.length === 0) return Promise.resolve();
    chain = chain.then(async () => {
      for (const { path, body } of posts) {
        try {
          await fetch(`http://127.0.0.1:${port}${path}`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ runId, ...body }),
            signal: AbortSignal.timeout(BRIDGE_TIMEOUT_MS),
          });
        } catch { /* bridge gone */ }
      }
    });
    return chain;
  };

  function route(event: any, terminalId: string | undefined, now: number): Post[] {
    const type = event?.type;
    const props = event?.properties ?? {};

    const notify = (kind: string, message?: string): Post => notifyPost(terminalId, kind, message);
    const handler = (kind: string, extra: Record<string, unknown> = {}): Post[] => handlerPosts(terminalId, kind, extra);

    // A session that has stopped cannot still be waiting on the user: opencode
    // drops a pending permission or question without any reply event when its
    // run is interrupted. Retired by id, the way an answer would have been.
    const retire = (sessionID: string): Post[] => {
      const posts: Post[] = [];
      for (const [id, owner] of prompts) {
        if (owner !== sessionID) continue;
        prompts.delete(id);
        posts.push(...handler("prompt_answered", { promptId: id }));
      }
      return posts;
    };

    // Two closers, because each can be dropped on its own: /notify collapses an
    // identical body inside its dedup window — two quick runs end with the same
    // `idle` post — while /handler-event turn_end closes the turn without
    // recording a notification.
    const endTurn = (sessionID: string): Post[] => {
      working.delete(sessionID);
      const errored = failed.has(sessionID);
      const message = failed.get(sessionID);
      failed.delete(sessionID);
      turnOpen = false;
      return [notify(errored ? "error" : "idle", message), ...handler("turn_end")];
    };

    switch (type) {
      case "session.created":
      case "session.updated": {
        const info = props.info ?? event.info;
        const sessionId = info?.id ?? props.sessionID;
        if (!sessionId) return [];
        // Root only for the title too. The bridge stores whatever id this posts
        // as the slot's resume id — so forwarding a child's would resume the
        // terminal into the subagent's conversation instead of the user's.
        if (info?.parentID) {
          children.add(sessionId);
          return [];
        }
        if (type !== "session.updated" || !terminalId) return [];
        // The id alone is enough to resume; forward it even before opencode has
        // named the conversation (title arrives on a later session.updated).
        return [{
          path: "/session-title",
          body: { terminalId, sessionId, title: info?.title || undefined, agent: "opencode" },
        }];
      }

      case "session.deleted": {
        const sessionId = props.info?.id ?? props.sessionID;
        if (!sessionId) return [];
        children.delete(sessionId);
        const posts = retire(sessionId);
        return working.has(sessionId) ? [...posts, ...endTurn(sessionId)] : posts;
      }

      case "session.status": {
        sawStatus = true;
        const sessionId = props.sessionID;
        const status = props.status?.type;
        if (!sessionId) return [];
        if (status === "idle") {
          const posts = retire(sessionId);
          // An idle for a session never seen busy is not the end of a turn this
          // plugin opened: opencode also reports idle for a cancel with nothing
          // running, and publishes one idle per layer that stops a run.
          return !children.has(sessionId) && working.has(sessionId) ? [...posts, ...endTurn(sessionId)] : posts;
        }
        // `retry` is a run waiting out a provider error before trying again —
        // still the same turn, still working.
        if (status !== "busy" && status !== "retry") return [];
        if (children.has(sessionId)) return [];
        working.add(sessionId);
        // The run went on after its error (an overflow it compacted away), so
        // that error is not how this run ends.
        failed.delete(sessionId);
        // No slot, no turn: the only closer left would be /notify, which can be
        // deduplicated away, and a turn with no closer wedges on "working".
        if (!terminalId) return [];
        if (!turnOpen) {
          turnOpen = true;
          lastAssertAt = now;
          return [{ path: "/turn-start", body: { terminalId } }];
        }
        if (now - lastAssertAt < ACTIVITY_INTERVAL_MS) return [];
        lastAssertAt = now;
        return [{ path: "/turn-activity", body: { terminalId } }];
      }

      // Deprecated by opencode and published right after session.status's idle,
      // so for a current opencode it only ever finds the turn already closed.
      case "session.idle": {
        const sessionId = props.sessionID;
        const posts = sessionId ? retire(sessionId) : [];
        if (sessionId && children.has(sessionId)) return posts;
        if (sessionId && working.has(sessionId)) return [...posts, ...endTurn(sessionId)];
        // Means "waiting for you", never task_complete — we never claim a
        // completion we can't verify.
        if (!sawStatus) return [...posts, notify("idle"), ...handler("turn_end")];
        return posts;
      }

      case "session.error": {
        const sessionId = props.sessionID;
        // A subagent's failure comes back to its parent as a tool result; the
        // parent's run is what decides whether the turn failed.
        if (sessionId && children.has(sessionId)) return [];
        // The user interrupting. The idle that follows ends the turn as done.
        if (props.error?.name === "MessageAbortedError") return [];
        const message = clip(props.error?.data?.message);
        if (sessionId && working.has(sessionId)) {
          failed.set(sessionId, message);
          return [];
        }
        return [notify("error", message)];
      }

      // `permission.updated` is the name opencode used before 2026-03 for the
      // same request; both still read.
      case "permission.asked":
      case "permission.updated": {
        const id = typeof props.id === "string" ? props.id : undefined;
        if (id) {
          if (prompts.has(id)) return [];
          prompts.set(id, props.sessionID);
        }
        const patterns = Array.isArray(props.patterns) ? props.patterns.join(", ") : "";
        const subject = props.permission ?? props.title;
        const message = clip(subject ? `opencode needs your permission for ${subject}${patterns ? `: ${patterns}` : ""}` : undefined);
        return [
          notify("permission_request", message),
          // `awaiting_input`, because /handler-event takes no permission kind:
          // the judge reads the block. The id lets the answer drop it before a
          // judge pass ever runs.
          ...handler("awaiting_input", id ? { promptId: id } : {}),
        ];
      }

      case "question.asked": {
        const id = typeof props.id === "string" ? props.id : undefined;
        if (id) {
          if (prompts.has(id)) return [];
          prompts.set(id, props.sessionID);
        }
        const first = Array.isArray(props.questions) ? props.questions[0] : undefined;
        const detail = clip(first?.question) ?? clip(first?.header);
        return [
          // Ahead of its /notify, matching the Claude hook: the question is put
          // on record before anything announces it.
          ...handler("question", { ...(id ? { promptId: id } : {}), ...(detail ? { detail } : {}) }),
          notify("question", detail),
        ];
      }

      // An answer, a rejection, or opencode settling a sibling request on the
      // user's "always"/"reject" all mean the same thing here: this prompt is no
      // longer on screen. Never a turn start — a rejection can end the run, and
      // a turn opened here would have no closer coming.
      case "permission.replied":
      case "question.replied":
      case "question.rejected": {
        const id = props.requestID ?? props.permissionID;
        if (typeof id !== "string" || !prompts.delete(id)) return [];
        return handler("prompt_answered", { promptId: id });
      }
    }
    return [];
  }

  return {
    event: async ({ event }: { event: any }) => {
      const port = process.env.ANTGRID_API_PORT;
      if (!port) return;
      return send(port, process.env.ANTGRID_RUN_ID, route(event, process.env.ANTGRID_TERMINAL_ID, Date.now()));
    },
    // An instance torn down mid-run (a config reload, a quit) cancels its runs,
    // and the idle that cancel publishes can race this plugin's own teardown.
    // Whatever is still open here has no other closer coming.
    dispose: async () => {
      const port = process.env.ANTGRID_API_PORT;
      if (!port || (working.size === 0 && !turnOpen)) return chain;
      const terminalId = process.env.ANTGRID_TERMINAL_ID;
      const posts = [...prompts.keys()].flatMap((id) => handlerPosts(terminalId, "prompt_answered", { promptId: id }));
      prompts.clear();
      working.clear();
      failed.clear();
      turnOpen = false;
      posts.push(notifyPost(terminalId, "idle"), ...handlerPosts(terminalId, "turn_end"));
      return send(port, process.env.ANTGRID_RUN_ID, posts);
    },
  };
};
