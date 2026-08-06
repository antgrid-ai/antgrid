import { readFileSync } from "node:fs";
import http from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";

// Antgrid session hook for Antigravity (`agy`). Registered as a named hook in
// ~/.gemini/config/hooks.json by the bridge (agent-launch-augmenter's
// ensureAntigravityHook). Fires on:
//   - PreInvocation (every turn, early): POSTs the conversation id (native resume
//     id for `agy --conversation <id>`) plus the per-conversation transcriptPath
//     agy's common hook fields already carry, so the bridge can derive a title
//     from the first user message right away.
//   - Stop: refreshes the title (titleOnly) and — unless the turn ended in a real
//     error — POSTs /notify so the app raises a "turn complete" notification
//     (mirrors cursor's post-notify.js).
// The title is deliberately resolved bridge-side, not here: this hook runs under
// bare `node`, which has no reliable sqlite reader for agy's global
// conversation_summaries.db (kept as a bonus upgrade path — see
// resolveStructuredTitle — but confirmed NOT populated during a live CLI
// session, even after a clean /exit; transcriptPath is the reliable source, see
// resolveAntigravityTranscriptTitle in agents/antigravity/title.ts).
//
// agy feeds the hook payload as JSON on stdin and reads a JSON object on
// stdout; we always emit `{}` so the agent loop is never gated or mutated — a
// Stop `{}` allows the stop, a PreInvocation `{}` injects nothing (pure observer).
//
// Hooks run SYNCHRONOUSLY and block agy's loop (every PreInvocation + Stop, every
// turn), so we don't wait on the HTTP *response* — the body carries nothing we
// need. But we DO wait for each request to finish flushing before exiting: the
// POSTs go to 127.0.0.1, which round-trips in single-digit ms, and exiting the
// instant they're queued (the earlier unref'd-socket approach) let the process
// tear down before libuv flushed the TCP write, silently dropping title/notify
// updates. A hard 4.5s timeout is the backstop so a stuck socket can never hold
// agy's loop hostage.
//
// agy has no per-spawn hook flag, so the hook is machine-global; a non-bridge
// `agy` run also triggers it but no-ops immediately (no ANTGRID_TERMINAL_ID).

const eventName = process.argv[2];
const isStop = eventName === "Stop";
const port = resolvePort();
const terminalId = process.env.ANTGRID_TERMINAL_ID;

let buffer = "";
let finished = false;
let resultWritten = false;
let pending = 0;

function resolvePort() {
  if (process.env.ANTGRID_API_PORT) return process.env.ANTGRID_API_PORT;
  try {
    const antgridDir = process.env.ANTGRID_DIR ?? join(homedir(), ".antgrid");
    const filePort = readFileSync(join(antgridDir, "api.port"), "utf8").trim();
    return filePort.length > 0 ? filePort : undefined;
  } catch {
    return undefined;
  }
}

// agy reads a JSON object from stdout; `{}` = no permission/step/termination
// changes. Writing the result unblocks agy's loop; we then linger only long
// enough for any in-flight POSTs to flush (see maybeExit).
function writeResult() {
  if (resultWritten) return;
  resultWritten = true;
  try {
    process.stdout.write("{}");
  } catch {
    // stdout already closed — nothing we can do, still exit cleanly.
  }
  maybeExit();
}

// Clean shutdown: once the result is written AND every POST has flushed to the
// OS (its socket then unref'd, see postJson), clear the backstop timer and let
// the event loop drain on its own. A NATURAL exit lets libuv transmit the
// already-queued socket writes; process.exit() would truncate them — that's the
// dropped-request bug we're avoiding, so this path never force-exits.
function maybeExit() {
  if (resultWritten && pending === 0) clearTimeout(timer);
}

// Hard exit: the no-op case (`!port`/`!terminalId`), a stdin error, and the
// timeout backstop. The first two have nothing queued to lose; the timeout
// deliberately cuts short a request that never flushed.
function finish() {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  writeResult();
  process.exit(0);
}

// Every agy hook payload carries these common fields (camelCase / protojson).
// conversationId is the agent-native id we resume with. "Stop" also carries an
// `error` field (non-empty only on a real failure) and `terminationReason` — but
// the latter is an internal enum that has already drifted from the bundled docs
// (observed "NO_TOOL_CALL" on a clean stop, not the documented "model_stop"), so
// `error` is the only field we key logic off.
function parsePayload(raw) {
  try {
    return JSON.parse(raw || "{}");
  } catch {
    return {};
  }
}

function conversationIdOf(payload) {
  const id = payload.conversationId ?? payload.conversation_id;
  return typeof id === "string" && id.trim() ? id.trim() : null;
}

// Every hook payload (PreInvocation and Stop alike) carries this from agy's own
// common fields — the per-conversation transcript JSONL under
// ~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/,
// written the instant the user's first message lands. Forwarded so the bridge
// can derive a title immediately (see resolveAntigravityTranscriptTitle)
// instead of waiting on conversation_summaries.db, which agy's CLI does not
// populate during a live session.
function transcriptPathOf(payload) {
  const p = payload.transcriptPath ?? payload.transcript_path;
  return typeof p === "string" && p.trim() ? p.trim() : null;
}

// Best-effort POST: we don't read the response (nothing we need), but the
// request socket stays ref'd until the body has flushed, so the process can't
// exit mid-write and drop it. We settle on `finish` (request fully handed to the
// OS) — NOT on the response — so a slow/absent bridge reply can't stall agy's
// loop; `error` settles the connection-refused case. First of the two wins.
function postJson(path, body) {
  const data = JSON.stringify(body);
  // Guard against a synchronous throw from http.request itself so it can't crash
  // the hook before writeResult() emits `{}` and unblocks agy's loop; async
  // failures are already swallowed by the "error" listener below.
  try {
    const req = http.request({
      hostname: "127.0.0.1",
      port,
      path,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(data),
      },
    });
    pending += 1;
    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      pending -= 1;
      maybeExit();
    };
    req.on("error", settle);
    req.on("finish", () => {
      // Body is flushed to the OS. Unref the socket now (not before — the old
      // unref-on-connect raced the flush) so awaiting the response never holds
      // the process open; the already-queued write still lands on natural exit.
      req.socket?.unref();
      settle();
    });
    req.write(data);
    req.end();
  } catch {
    // Best-effort — a request that never launched has nothing to flush or await.
  }
}

function run(payload) {
  const conversationId = conversationIdOf(payload);
  const transcriptPath = transcriptPathOf(payload);
  if (!port || !terminalId) return finish();

  if (conversationId) {
    postJson("/session-title", {
      terminalId,
      sessionId: conversationId,
      agent: "antigravity",
      ...(transcriptPath ? { transcriptPath } : {}),
      ...(isStop ? { titleOnly: true } : {}),
    });
  }

  // Notify unless the turn ended in a real error — the agent has stopped and is
  // now waiting on the user (a clean stop or hitting the step cap both qualify;
  // only a genuine failure should stay silent, matching cursor's completed-only
  // rule in spirit without pinning to agy's undocumented reason enum).
  // terminalId names the session in the notification title (bridge reads it back
  // via SessionManager) — always set here, guaranteed truthy by the guard above.
  if (isStop && !payload.error) {
    postJson("/notify", { type: "task_complete", terminalId });
  }

  // Unblock agy's loop now; the process then lingers only until the POST(s)
  // above finish flushing to localhost, so their writes are never dropped.
  writeResult();
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
});
process.stdin.on("end", () => run(parsePayload(buffer)));
process.stdin.on("error", finish);

// Hooks run synchronously and block the agy loop — never hang.
const timer = setTimeout(finish, 4_500);
