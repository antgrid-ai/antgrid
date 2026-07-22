export type NotificationKind = "osc9" | "osc777" | "title";

export interface NotificationEvent {
  kind: NotificationKind;
  title?: string;
  body?: string;
}

const MAX_OSC_BYTES = 2048;
const BEL = 0x07;
const ESC = 0x1b;

type State = "ground" | "esc" | "osc" | "osc_esc" | "dcs" | "dcs_esc";

/**
 * Detects terminal desktop-notification signals in a PTY output stream.
 * Mirrors Ghostty's src/terminal/osc.zig rules (see the design doc):
 * OSC 9 with ConEmu numeric subcommands (9;4 progress, 9;9 set-CWD, …)
 * filtered; OSC 777 `notify` only; 2 KB cap; partial sequences buffered across
 * feed() calls. A bare BEL is NOT a notification — it passes through to the
 * terminal renderer, which rings it audibly like any native terminal.
 * Pure — `nowMs` is injected so tests are deterministic.
 */
export class TerminalNotificationScanner {
  private state: State = "ground";
  private oscBuf = "";
  private oscOverflow = false;

  feed(chunk: string, nowMs: number): NotificationEvent[] {
    const events: NotificationEvent[] = [];
    for (let i = 0; i < chunk.length; i++) {
      const c = chunk.charCodeAt(i);
      const ch = chunk[i];
      switch (this.state) {
        case "ground":
          // A bare BEL is intentionally ignored — it stays in the raw stream
          // and the renderer rings it (native-terminal bell), it is never a
          // desktop notification. Only OSC 9/777 below raise notifications.
          if (c === ESC) this.state = "esc";
          break;
        case "esc":
          if (c === 0x5d /* ] */) { this.state = "osc"; this.oscBuf = ""; this.oscOverflow = false; }
          else if (c === 0x50 /* P */ || c === 0x5f /* _ */ || c === 0x5e /* ^ */ || c === 0x58 /* X */) this.state = "dcs";
          else this.state = "ground";
          break;
        case "osc":
          if (c === BEL) { this.finishOsc(events); this.state = "ground"; }
          else if (c === ESC) this.state = "osc_esc";
          else this.appendOsc(ch);
          break;
        case "osc_esc":
          if (c === 0x5c /* \ */) { this.finishOsc(events); this.state = "ground"; }
          else if (c === ESC) { /* stay, another ESC */ }
          else { this.oscBuf = ""; this.oscOverflow = false; this.state = "ground"; }
          break;
        case "dcs":
          if (c === ESC) this.state = "dcs_esc";
          break;
        case "dcs_esc":
          if (c === 0x5c /* \ */) this.state = "ground";
          else if (c === ESC) { /* stay */ }
          else this.state = "dcs";
          break;
      }
    }
    return events;
  }

  private appendOsc(ch: string): void {
    if (this.oscOverflow) return;
    if (this.oscBuf.length >= MAX_OSC_BYTES) { this.oscOverflow = true; return; }
    this.oscBuf += ch;
  }

  private finishOsc(events: NotificationEvent[]): void {
    const overflow = this.oscOverflow;
    const body = this.oscBuf;
    this.oscBuf = "";
    this.oscOverflow = false;
    if (overflow) return;
    const sep = body.indexOf(";");
    const prefix = sep === -1 ? body : body.slice(0, sep);
    const rest = sep === -1 ? "" : body.slice(sep + 1);
    if (prefix === "9") {
      if (rest.length === 0) return;            // empty → ignore
      if (/^\d+(;|$)/.test(rest)) return;       // ConEmu numeric subcommand (progress 9;4, set-CWD 9;9, …) → drop
      events.push({ kind: "osc9", body: rest });
    } else if (prefix === "777") {
      const parts = rest.split(";");
      if (parts[0] !== "notify") return;
      events.push({ kind: "osc777", title: parts[1] ?? "", body: parts.slice(2).join(";") });
    } else if (prefix === "0" || prefix === "2") {
      // OSC 0 sets icon name + window title; OSC 2 sets window title. `rest` is
      // the title (embedded ';' kept). Empty = clear; emit it and let the
      // consumer ignore empties so a cleared title never overwrites a good name.
      events.push({ kind: "title", title: rest });
    }
    // other OSC numbers → ignore
  }
}
