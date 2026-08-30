// The bar these tests hold the attach path to is RECONSTRUCTION, not delivery:
// a returning app rebuilds its VT engine from the blob alone, so the blob has
// to reproduce the source screen exactly, from whatever state the app's engine
// happens to be sitting in, with no help from the bytes that originally drew it.
import { describe, test, expect } from "bun:test";
import { TerminalScreen } from "../src/terminal-screen";
import { TerminalManager } from "../src/terminal-manager";
import { createConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";

const ESC = "\x1b";

/** The shape this whole design exists for: an Ink-style TUI that paints its
 *  chrome once and thereafter rewrites only the bottom rows. */
function paintAgentScreen(screen: TerminalScreen): void {
  screen.feed(`${ESC}[?1049h${ESC}[?1000h${ESC}[?1006h${ESC}[2J${ESC}[H`);
  for (let row = 1; row <= 50; row++) {
    screen.feed(`${ESC}[${row};1H${ESC}[38;5;${row % 200}m` + `row ${row} `.padEnd(199, "-"));
  }
  for (let i = 0; i < 3000; i++) {
    screen.feed(`${ESC}[${40 + (i % 8)};1H${ESC}[K token ${i} streaming into the bottom pane`);
  }
}

describe("TerminalScreen", () => {
  test("a snapshot fed into a fresh screen reproduces the source exactly", async () => {
    const source = new TerminalScreen(200, 50);
    paintAgentScreen(source);
    const blob = await source.snapshot();

    const restored = new TerminalScreen(200, 50);
    restored.feed(blob);

    expect(await restored.snapshot()).toBe(blob);
    // The diffs the tail of the byte stream would have carried are only a few
    // of the fifty rows; the header the program painted once is the half a
    // suffix can no longer address.
    expect(blob).toContain("row 1 ");
    source.dispose();
    restored.dispose();
  });

  test("reconstruction does not depend on what the destination engine was showing", async () => {
    const source = new TerminalScreen(200, 50);
    source.feed("primary history line\r\n".repeat(60));
    paintAgentScreen(source);
    const blob = await source.snapshot();

    // Whichever buffer the engine is on when the blob lands is exactly what
    // `ATTACH_PREAMBLE`'s byte order settles: `?1049l` before the erase, or the
    // erase clears a buffer the replay never targets and the stale one shows
    // through.
    const virgin = new TerminalScreen(200, 50);
    const staleAlt = new TerminalScreen(200, 50);
    staleAlt.feed(`${ESC}[?1049h${ESC}[H content from the session the user just left`);
    const dirtyPrimary = new TerminalScreen(200, 50);
    dirtyPrimary.feed("stale primary content\r\n".repeat(80));

    for (const destination of [virgin, staleAlt, dirtyPrimary]) {
      destination.feed(blob);
      expect(await destination.snapshot()).toBe(blob);
      destination.dispose();
    }
    source.dispose();
  });

  test("the cursor lands where the source left it, on the source's buffer", async () => {
    const source = new TerminalScreen(200, 50);
    source.feed(`${ESC}[?1049h${ESC}[2J${ESC}[H`);
    source.feed(`${ESC}[12;40Hprompt> `);
    const blob = await source.snapshot();

    const restored = new TerminalScreen(200, 50);
    restored.feed(blob);
    await restored.snapshot();

    const before = bufferOf(source);
    const after = bufferOf(restored);
    expect(after.type).toBe("alternate");
    expect(after.cursorY).toBe(before.cursorY);
    expect(after.cursorX).toBe(before.cursorX);
    source.dispose();
    restored.dispose();
  });

  test("output dropped while suppressed still reaches the next attach", async () => {
    const sent: AbMessage[] = [];
    const connState = createConnState();
    const manager = new TerminalManager((msg) => sent.push(msg), undefined, connState);
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 400));

    const outputsBefore = sent.filter((m) => m.type === "terminal:output").length;
    const seqBefore = manager.getScrollback("t1")!.seq;

    connState.appFocusPaused = true;
    manager.write("t1", "echo antgrid-suppressed-marker\n");
    await new Promise((r) => setTimeout(r, 1200));

    expect(sent.filter((m) => m.type === "terminal:output").length).toBe(outputsBefore);
    expect(manager.getScrollback("t1")!.seq).toBeGreaterThan(seqBefore);

    // The emulator is fed BEFORE the suppression drop, which is the only reason
    // the window a socket drop or a backgrounded app opens is recoverable at all.
    const snap = await manager.getAttachSnapshot("t1");
    expect(snap!.text).toContain("antgrid-suppressed-marker");

    manager.killAll();
  });

  test("a screen is released with its terminal, and retained with its scrollback", async () => {
    const connState = createConnState();
    const manager = new TerminalManager(() => {}, undefined, connState);
    const screens = screensOf(manager);

    manager.spawn({ terminalId: "forgotten" });
    await new Promise((r) => setTimeout(r, 200));
    manager.forget("forgotten");
    expect(screens.has("forgotten")).toBe(false);

    const exiting = manager.spawn(shortLivedSpawn({ terminalId: "exiting" }));
    const retained = manager.spawn(
      shortLivedSpawn({ terminalId: "retained", retainScrollbackOnExit: true }),
    );
    await waitFor(() => !manager.has(exiting) && !manager.has(retained), "both PTYs to exit");
    expect(screens.has("exiting")).toBe(false);
    // The `worktree.setup` transcript is read AFTER its run failed, so its
    // screen has to survive its own exit.
    expect(screens.has("retained")).toBe(true);

    manager.spawn({ terminalId: "respawn" });
    const first = screens.get("respawn");
    manager.spawn({ terminalId: "respawn" });
    await new Promise((r) => setTimeout(r, 200));
    expect(screens.get("respawn")).not.toBe(first);

    manager.killAll();
    expect(screens.size).toBe(0);
  });

  test("the emulator is a pure sink and can never answer the guest", () => {
    const screen = new TerminalScreen(80, 24);
    // `vt-capability-responder.ts` answers the guest's DA/DECRQM queries; a
    // second answerer on the same PTY sends duplicates.
    expect(Object.getOwnPropertyNames(TerminalScreen.prototype).sort())
      .toEqual([
        "constructor", "dispose", "feed", "hasPendingTail", "isDisposed",
        "pendingTail",
        "resize", "serializeNow", "settle", "snapshot",
      ]);
    screen.feed(`${ESC}[c${ESC}[?1000$p`);
    // Reaching for the emitter's own listener count is the only way to prove a
    // handler was never registered; if the internals move the assertion fails
    // loudly rather than passing vacuously.
    expect(onDataListenerCount(screen)).toBe(0);
    screen.dispose();
  });

  test("the destination's own history survives an attach, however many land", async () => {
    // The app's engine holds 10 000 lines and outlives every attach; the blob
    // carries none of them. So the attach may only ever repaint the SCREEN —
    // an erase that reached the buffer above it (`3J`) would destroy the user's
    // history with nothing able to put it back.
    const source = new TerminalScreen(200, 50);
    paintAgentScreen(source);
    const blob = await source.snapshot();
    expect(blob).not.toContain(`${ESC}[3J`);

    const destination = new TerminalScreen(200, 50);
    destination.feed("user history line\r\n".repeat(120));
    await destination.snapshot();
    const history = primaryHistoryDepth(destination);
    expect(history).toBeGreaterThan(0);

    // Twice: the body is exactly one screen, so it fills the rows the erase
    // cleared and scrolls nothing into the buffer above — which is what makes a
    // repeated re-attach idempotent without an erase that reaches history.
    for (let attach = 0; attach < 2; attach++) {
      destination.feed(blob);
      await destination.snapshot();
      expect(primaryHistoryDepth(destination)).toBe(history);
      expect(visibleRows(destination)).toEqual(visibleRows(source));
    }

    source.dispose();
    destination.dispose();
  });

  test("a cold attach carries the history a warm one must not", async () => {
    // The two callers want opposite things and only one of them can be the
    // default. A RE-attach must protect the app's own far deeper history, so it
    // ships the screen alone. A COLD attach has no history to protect and one
    // screen is a real loss — a scrolling build log (the worktree setup
    // transcript) re-opened on a second device showed its last rows and nothing
    // above them.
    const source = new TerminalScreen(80, 10);
    for (let i = 1; i <= 60; i++) source.feed(`build step ${i}\r\n`);

    const warm = await source.snapshot();
    expect(warm).not.toContain(`${ESC}[3J`);
    expect(warm).not.toContain("build step 1 ");
    expect(warm).toContain("build step 60");

    const cold = await source.snapshot({ history: true });
    // The erase is what lets a body taller than the screen scroll into the
    // buffer above without stacking a second copy on a repeat.
    expect(cold).toContain(`${ESC}[3J`);
    expect(cold).toContain("build step 1\r\n");
    expect(cold).toContain("build step 60");

    source.dispose();
  });

  test("a cold attach reconstructs history and stays idempotent", async () => {
    const source = new TerminalScreen(80, 10);
    for (let i = 1; i <= 60; i++) source.feed(`build step ${i}\r\n`);
    const cold = await source.snapshot({ history: true });

    const destination = new TerminalScreen(80, 10);
    destination.feed(cold);
    await destination.snapshot();
    expect(visibleRows(destination)).toEqual(visibleRows(source));
    const history = primaryHistoryDepth(destination);
    expect(history).toBeGreaterThan(0);

    // Repeat attaches must not stack: the body is taller than the screen, so
    // without the preamble's own `3J` each one would push another copy of the
    // same log into the buffer above.
    for (let attach = 0; attach < 2; attach++) {
      destination.feed(cold);
      await destination.snapshot();
      expect(primaryHistoryDepth(destination)).toBe(history);
      expect(visibleRows(destination)).toEqual(visibleRows(source));
    }

    source.dispose();
    destination.dispose();
  });

  test("a scroll region left behind by an earlier guest does not survive", async () => {
    // Margins are latched in the app's long-lived engine, and the serialized
    // body places its rows with CR/LF and relative moves — every one of them
    // region-sensitive. Without the preamble's `[r` a stale band collapses the
    // whole restore into a few rows.
    const source = new TerminalScreen(80, 12);
    for (let row = 1; row <= 12; row++) {
      source.feed(`${ESC}[${row};1H` + `source row ${row} `.padEnd(79, "-"));
    }
    const blob = await source.snapshot();

    const destination = new TerminalScreen(80, 12);
    destination.feed(`${ESC}[2;5r`);
    destination.feed(blob);
    await destination.snapshot();

    expect(visibleRows(destination)).toEqual(visibleRows(source));
    source.dispose();
    destination.dispose();
  });

  test("an incompressible screen is sent whole rather than truncated", async () => {
    const screen = new TerminalScreen(120, 30);
    // Distinct truecolor fg+bg per cell is the pathological case: nothing in
    // the serializer can coalesce it, and there is no history left to shed —
    // the blob is already the visible grid alone. A half-drawn screen is worse
    // than a large frame, so MAX_ATTACH_BLOB warns and gates nothing.
    for (let row = 0; row < 240; row++) {
      const cells: string[] = [];
      for (let col = 0; col < 120; col++) {
        const n = (row * 120 + col) % 255;
        cells.push(`${ESC}[38;2;${n};${(n * 7) % 255};${(n * 13) % 255}m`);
        cells.push(`${ESC}[48;2;${(n * 3) % 255};${n};${(n * 5) % 255}mX`);
      }
      screen.feed(cells.join("") + "\r\n");
    }

    const blob = await screen.snapshot();
    const restored = new TerminalScreen(120, 30);
    restored.feed(blob);
    await restored.snapshot();
    expect(visibleRows(restored)).toEqual(visibleRows(screen));

    screen.dispose();
    restored.dispose();
  });

  test("the pending tail carries only what the barrier did not consume", async () => {
    const screen = new TerminalScreen(80, 24);
    // One row, no line terminator: what matters is which HALF of the
    // attach carries the marker, not where it landed.
    screen.feed("BASE ");
    // Drained first on purpose: with a write already queued, xterm's own flush
    // timer runs ahead of the one below and the race never happens.
    await screen.settle();

    // The realistic shape — a PTY data callback already pending when the attach
    // starts, so its chunk is queued behind the barrier's empty write and
    // parsed in the SAME 12 ms slice the barrier's callback fires from. The
    // callback only queues a microtask, so the `await` continuation resumes
    // AFTER the parser has consumed it.
    setTimeout(() => screen.feed("MIDBARRIER"), 0);
    await screen.settle();

    const attach = screen.serializeNow() + screen.pendingTail();
    // Once, whichever half it came from. Replaying every chunk observed during
    // the barrier put it in both, and an attach against a streaming build log
    // then stacked those duplicates into the user's own scrollback on every
    // focus resume, unfilterable — their seq is at or below the blob's cutoff.
    expect(attach.split("MIDBARRIER").length - 1).toBe(1);
    screen.dispose();
  });
  test("the erase runs under default attributes, not a latched background", async () => {
    // The ordinary TUI shape: a guest sets a background and THEN takes the
    // alternate screen, so the `?1049h` saves that background and the
    // preamble's own `?1049l` restores it. `ED` honours background-colour-
    // erase, so an erase reached in that state paints every cell the body does
    // not overwrite — the whole tab comes back coloured behind the screen.
    const destination = new TerminalScreen(20, 5);
    destination.feed(ESC + "[41m" + ESC + "[?1049h" + ESC + "[H" + "alt screen");
    await destination.snapshot();

    const source = new TerminalScreen(20, 5);
    source.feed("hello");
    destination.feed(await source.snapshot());
    await destination.snapshot();

    expect(isDefaultBackground(destination, 3, 10)).toBe(true);
    expect(isDefaultBackground(destination, 0, 10)).toBe(true);
    source.dispose();
    destination.dispose();
  });
});

function shortLivedSpawn(base: { terminalId: string; retainScrollbackOnExit?: boolean }) {
  const isWin = process.platform === "win32";
  return {
    ...base,
    command: isWin ? "cmd.exe" : "sh",
    args: isWin ? ["/d", "/s", "/c", "echo done"] : ["-c", "echo done"],
  };
}

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

function screensOf(manager: TerminalManager): Map<string, unknown> {
  return (manager as unknown as { screens: Map<string, unknown> }).screens;
}

function bufferOf(screen: TerminalScreen): { type: string; cursorX: number; cursorY: number } {
  return (screen as unknown as { term: { buffer: { active: { type: string; cursorX: number; cursorY: number } } } })
    .term.buffer.active;
}

/** Lines the primary buffer holds above its viewport — the user's own history. */
function primaryHistoryDepth(screen: TerminalScreen): number {
  const term = (screen as unknown as {
    term: { rows: number; buffer: { normal: { length: number } } };
  }).term;
  return term.buffer.normal.length - term.rows;
}

function visibleRows(screen: TerminalScreen): string[] {
  const term = (screen as unknown as {
    term: { rows: number; buffer: { active: { viewportY: number; getLine(i: number): { translateToString(trim?: boolean): string } | undefined } } };
  }).term;
  const buffer = term.buffer.active;
  const rows: string[] = [];
  for (let i = 0; i < term.rows; i++) {
    rows.push(buffer.getLine(buffer.viewportY + i)?.translateToString(true) ?? "");
  }
  return rows;
}

function isDefaultBackground(screen: TerminalScreen, row: number, col: number): boolean {
  const term = (screen as unknown as {
    term: { buffer: { active: { getLine(i: number): { getCell(c: number): { isBgDefault(): boolean } | undefined } | undefined } } };
  }).term;
  const cell = term.buffer.active.getLine(row)?.getCell(col);
  if (cell === undefined) throw new Error(`no cell at ${row},${col}`);
  return cell.isBgDefault();
}

function onDataListenerCount(screen: TerminalScreen): number {
  return (screen as unknown as { term: { _core: { _onData: { _size: number } } } })
    .term._core._onData._size;
}
