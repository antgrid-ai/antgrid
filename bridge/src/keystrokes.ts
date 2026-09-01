// bridge/src/keystrokes.ts

// Classification of one inbound `terminal:input` payload. A leaf module with no
// imports on purpose: agent-core.ts imports handler/engine.ts, so the handler
// reaching back into agent-core for these would close a cycle.

/**
 * Whether a `terminal:input` payload submitted a prompt. Two consumers: the
 * work-status turn inference agents without a pre-turn hook depend on (see
 * work-status.ts), and the handler's submitted-line gate (`onUserReply` in
 * handler/engine.ts), which resets the runaway guard and retires pending
 * escalations.
 *
 * A TUI submits on CR, so that's the signal — but only as the FINAL byte, and
 * never behind ESC: `\x1b\r` is alt+enter, which inserts a newline into a
 * multi-line prompt rather than sending it. Treating that as a submit would open
 * a turn nothing is going to close, which is exactly the stale "working" dot the
 * turn model exists to avoid. Shift+enter under the kitty protocol
 * (`\x1b[13;2u`) carries no CR at all and needs no special case.
 */
export function isSubmitKeystroke(data: string): boolean {
  return data.endsWith("\r") && !data.endsWith("\x1b\r");
}

/**
 * Reports the terminal EMITS rather than input a human gave it: mouse tracking
 * (SGR `\x1b[<b;x;yM|m`, X10 `\x1b[M` + 3 bytes, urxvt `\x1b[b;x;yM`) and focus
 * in/out (`\x1b[I`, `\x1b[O`).
 *
 * A coding agent turns mouse reporting on as it starts, so once the pointer is
 * over the terminal these arrive continuously, one frame each, from a user who
 * has touched no key.
 */
function isPointerOrFocusReport(data: string): boolean {
  return /^\x1b\[(?:<\d+;\d+;\d+[Mm]|M[\s\S]{3}|\d+;\d+;\d+M|[IO])$/.test(data);
}

/**
 * Whether a `terminal:input` payload carried anything BESIDES the submitting CR.
 *
 * A PTY delivers one keystroke per frame, so the CR that submits a prompt almost
 * always arrives alone — which makes {@link isSubmitKeystroke} on its own unable
 * to tell "the user sent a prompt" from "the user pressed enter on an empty
 * prompt, or to dismiss a TUI menu". The latter starts no turn, so nothing will
 * ever close the one it opens. work-status.ts pairs the two: a keystroke-inferred
 * turn needs typed content since the last one (see `typedSessions`).
 *
 * Escape sequences count as content on purpose — arrow-key history recall then
 * enter IS a submit, and the alternative (dropping it) loses a real turn. The one
 * exception is a sequence the TERMINAL wrote rather than the user: `typedSessions`
 * outlives the frame that set it, so a single pointer move makes the next bare
 * Enter — on a TUI menu, on an empty prompt — open a turn no stop hook will ever
 * close, and the session holds a "working" dot for the rest of its life.
 */
export function hasTypedContent(data: string): boolean {
  if (isPointerOrFocusReport(data)) return false;
  return data.replace(/\r$/, "").length > 0;
}

/**
 * The prompt inside a `terminal:input` frame that submitted one, CR stripped —
 * or null when the frame is not that shape.
 *
 * A frame carrying content AND ending in a submitting CR is a whole prompt in
 * one write, which is exactly the shape a guest tokenizer absorbs the CR into
 * (see pty-submit.ts); it has to be re-split before it reaches the PTY. A bare
 * `\r`, an `\x1b\r`, or content with no CR is written through untouched — the
 * first accepts a TUI default and must not be re-shaped, the second submits
 * nothing at all.
 *
 * An interior CR stays inside the body: only the SUBMITTING one is separated.
 */
export function submittedLine(data: string): string | null {
  return isSubmitKeystroke(data) && hasTypedContent(data) ? data.slice(0, -1) : null;
}

/**
 * Whether a `terminal:input` payload was a bare Escape keypress — the
 * interactive interrupt shortcut every agent CLI honors, and the only signal
 * a hook-based session gets that the user meant to abort a running turn.
 *
 * Exactly `\x1b` and nothing else: any longer sequence starting with ESC
 * (arrow keys, function keys, alt+key, kitty-protocol chunks, alt+enter's
 * `\x1b\r`) is content, not an interrupt, and must not be misread as one — a
 * PTY assembles a full escape sequence before writing it, so a lone ESC byte
 * in one frame unambiguously means the user pressed just that key.
 */
export function isInterruptKeystroke(data: string): boolean {
  return data === "\x1b";
}
