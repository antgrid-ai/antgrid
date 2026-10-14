import { createHash } from "node:crypto";
import { CLIPBOARD_MAX_WIRE_BYTES, decodeClipboardText } from "./limits";

export interface ClipboardScanEvent<T> { owner: T | undefined; text: string }
export interface ClipboardScanResult<T> { output: string; writes: ClipboardScanEvent<T>[]; replies: string[] }

/** Only live PTY ingress owns this parser; reconstructed screens must never feed it. */
export class TerminalClipboardScanner<T = number> {
  private pending = "";
  private pendingBytes = 0;
  private kind: "escape" | "osc" | "dcs" | "other" | undefined;
  private owner: T | undefined;
  private overflow = false;
  private escapeRun = 0;
  private tmux = false;
  private suppressClipboard = false;
  private tokens = 3;
  private readTokens = 3;
  private refillAt: number;
  private duplicate?: { hash: string; owner: T | undefined; at: number };

  constructor(
    private readonly captureOwner: () => T | undefined = () => undefined,
    private readonly now: () => number = () => performance.now(),
    private readonly allowTmux = true,
  ) { this.refillAt = now(); }

  feed(chunk: string): ClipboardScanResult<T> {
    const result: ClipboardScanResult<T> = { output: "", writes: [], replies: [] };
    for (const char of chunk) {
      if (!this.kind) {
        if (char === "\x1b" || "\x90\x98\x9d\x9e\x9f".includes(char)) {
          this.begin(char);
        } else result.output += char;
        continue;
      }
      if (this.kind !== "escape" && !this.tmux) {
        if (this.escapeRun > 0 && char !== "\\") {
          // ESC starts a fresh VT command even when the previous string never
          // terminated. Discard its body, then parse the new escape normally.
          this.reset();
          this.begin("\x1b");
          this.suppressClipboard = true;
        } else if ("\x90\x98\x9d\x9e\x9f".includes(char)) {
          this.reset();
          this.begin(char);
          this.suppressClipboard = true;
          continue;
        }
      }
      if (this.kind === "escape") {
        if (/[\x00-\x17\x19\x1c-\x1f\x7f]/.test(char)) {
          result.output += char;
        } else if ("]PX^_".includes(char)) {
          this.pending += char;
          this.pendingBytes += 1;
          this.kind = char === "]" ? "osc" : char === "P" ? "dcs" : "other";
          this.escapeRun = 0;
        } else {
          result.output += this.pending;
          const suppressClipboard = this.suppressClipboard;
          this.reset();
          if (char === "\x1b" || "\x90\x98\x9d\x9e\x9f".includes(char)) {
            this.begin(char);
            this.suppressClipboard = suppressClipboard;
          } else result.output += char;
        }
        continue;
      }
      const cancelled = char === "\x18" || char === "\x1a";
      const terminated = char === "\x9c" || (char === "\x07" && this.kind === "osc") ||
        (char === "\\" && (this.tmux ? this.escapeRun % 2 === 1 : this.escapeRun > 0));
      if (!this.overflow) {
        const bytes = Buffer.byteLength(char, "utf8");
        if (this.pendingBytes + bytes > CLIPBOARD_MAX_WIRE_BYTES) this.overflow = true;
        else { this.pending += char; this.pendingBytes += bytes; }
        // Rechecking a growing rope's prefix on every byte repeatedly flattens it.
        if (this.kind === "dcs" && this.pending.length === 7) this.tmux = this.pending === "\x1bPtmux;";
      }
      if (cancelled || terminated) {
        if (!this.overflow) this.finish(result, cancelled);
        this.reset();
      } else this.escapeRun = char === "\x1b" ? this.escapeRun + 1 : 0;
    }
    return result;
  }

  dispose(): void { this.reset(); this.duplicate = undefined; }

  private begin(char: string): void {
    this.owner = this.captureOwner();
    this.pending = char;
    this.pendingBytes = Buffer.byteLength(char, "utf8");
    this.kind = char === "\x1b" ? "escape" : char === "\x9d" ? "osc" : char === "\x90" ? "dcs" : "other";
    this.escapeRun = char === "\x1b" ? 1 : 0;
  }

  private reset(): void {
    this.pending = ""; this.pendingBytes = 0; this.kind = undefined; this.owner = undefined; this.overflow = false; this.escapeRun = 0; this.tmux = false; this.suppressClipboard = false;
  }

  private takeToken(read: boolean): boolean {
    const now = this.now();
    const refill = Math.max(0, now - this.refillAt) / 1000;
    this.refillAt = now;
    this.tokens = Math.min(3, this.tokens + refill);
    this.readTokens = Math.min(3, this.readTokens + refill);
    if ((read ? this.readTokens : this.tokens) < 1) return false;
    if (read) this.readTokens--; else this.tokens--;
    return true;
  }

  private finish(result: ClipboardScanResult<T>, cancelled: boolean): void {
    const raw = this.pending;
    const endLength = raw.endsWith("\x1b\\") ? 2 : 1;
    if (this.kind === "dcs" && this.allowTmux && raw.startsWith("\x1bPtmux;")) {
      if (cancelled || this.suppressClipboard) return;
      const encoded = raw.slice(7, -endLength);
      // An exact passthrough doubles every ESC; malformed wrappers fail closed.
      if (/(?:^|[^\x1b])(?:\x1b\x1b)*\x1b(?:[^\x1b]|$)/.test(encoded)) return;
      const inner = new TerminalClipboardScanner(() => this.owner, this.now, false);
      const decoded = inner.feed(encoded.replaceAll("\x1b\x1b", "\x1b"));
      if (decoded.output) result.output += `\x1bPtmux;${decoded.output.replaceAll("\x1b", "\x1b\x1b")}\x1b\\`;
      for (const event of decoded.writes) this.write(event.text, result);
      for (const reply of decoded.replies) if (this.takeToken(true)) result.replies.push(reply);
      return;
    }
    // A nested OSC introducer cancels/restarts the VT string. Never release
    // such malformed outer strings to diagnostics or execute their side effects.
    const contentStart = raw.startsWith("\x1b") ? 2 : 1;
    if (/(?:\x1b[\x00-\x17\x19\x1c-\x1f\x7f]*\]|\x9d)/.test(raw.slice(contentStart))) return;
    const body = this.kind === "osc" ? raw.slice(raw.startsWith("\x1b") ? 2 : 1, -endLength) : "";
    const firstDelimiter = body.indexOf(";");
    // The VT ignores these C0 bytes and accumulates the command numerically.
    const command = (firstDelimiter < 0 ? body : body.slice(0, firstDelimiter)).replace(/[\x00-\x06\x08-\x17\x19\x1c-\x1f]/g, "");
    if (!/^0*52$/.test(command)) { result.output += raw; return; }
    if (cancelled || this.suppressClipboard) return;
    if (firstDelimiter < 0) return;
    const delimiter = body.indexOf(";", firstDelimiter + 1);
    if (delimiter < 0) return;
    const selector = body.slice(firstDelimiter + 1, delimiter);
    if (selector.length > 16 || !/^[cspq0-7]*$/.test(selector) || (selector !== "" && !/[csp]/.test(selector))) return;
    const payload = body.slice(delimiter + 1);
    if (payload === "?") {
      if (this.takeToken(true)) {
        const supported = [...selector].filter((c) => "csp".includes(c)).join("");
        result.replies.push(`\x1b]52;${supported};${raw.slice(-endLength)}`);
      }
      return;
    }
    const text = decodeClipboardText(payload);
    if (text !== undefined) this.write(text, result);
  }

  private write(text: string, result: ClipboardScanResult<T>): void {
    const hash = createHash("sha256").update(text).digest("hex");
    const now = this.now();
    if (this.duplicate?.hash === hash && this.duplicate.owner === this.owner && now - this.duplicate.at <= 250) return;
    if (!this.takeToken(false)) return;
    this.duplicate = { hash, owner: this.owner, at: now };
    result.writes.push({ owner: this.owner, text });
  }
}
