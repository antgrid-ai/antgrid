import { describe, it, expect } from "bun:test";
import { padBareVerb, PtySubmitQueue, SUBMIT_CR_GAP_MS } from "../src/pty-submit";

const tick = () => new Promise<void>((r) => setTimeout(r, 0));

/** A gap the test opens and closes by hand, so the window between a line and
 *  its CR is observable rather than raced. */
function gate() {
  const asked: number[] = [];
  let pending: (() => void) | null = null;
  return {
    asked,
    sleep(ms: number) {
      asked.push(ms);
      return new Promise<void>((resolve) => {
        pending = resolve;
      });
    },
    /** Runs the queue to a standstill, releasing each gap as it opens. */
    async drain(): Promise<void> {
      for (let i = 0; i < 8; i++) {
        await tick();
        if (!pending) continue;
        const resolve = pending;
        pending = null;
        resolve();
      }
      await tick();
    },
  };
}

describe("PtySubmitQueue", () => {
  it("writes through synchronously while idle", () => {
    const writes: string[] = [];
    const q = new PtySubmitQueue({ write: (d) => writes.push(d) });
    q.write("a");
    // Asserted before any await: the keystroke hot path must not grow a
    // scheduling hop.
    expect(writes).toEqual(["a"]);
  });

  it("holds the CR back until the gap has elapsed", async () => {
    const writes: string[] = [];
    const g = gate();
    const q = new PtySubmitQueue({ write: (d) => writes.push(d), sleep: g.sleep });
    q.submit("hello");
    await Promise.resolve();
    expect(writes).toEqual(["hello"]);
    expect(g.asked).toEqual([SUBMIT_CR_GAP_MS]);
    await g.drain();
    expect(writes).toEqual(["hello", "\r"]);
  });

  it("orders a keystroke arriving mid-submit after the CR", async () => {
    const writes: string[] = [];
    const g = gate();
    const q = new PtySubmitQueue({ write: (d) => writes.push(d), sleep: g.sleep });
    q.submit("hello");
    await Promise.resolve();
    // Written through, the key would land INSIDE the injected line.
    q.write("x");
    expect(writes).toEqual(["hello"]);
    await g.drain();
    expect(writes).toEqual(["hello", "\r", "x"]);
  });

  it("does not interleave two submits", async () => {
    const writes: string[] = [];
    const g = gate();
    const q = new PtySubmitQueue({ write: (d) => writes.push(d), sleep: g.sleep });
    q.submit("a");
    q.submit("b");
    await g.drain();
    expect(writes).toEqual(["a", "\r", "b", "\r"]);
  });

  it("keeps accepting writes after the raw writer throws", async () => {
    const writes: string[] = [];
    const g = gate();
    let dead = true;
    const q = new PtySubmitQueue({
      write: (d) => {
        if (dead) throw new Error("PTY gone");
        writes.push(d);
      },
      sleep: g.sleep,
    });
    q.submit("doomed");
    await g.drain();
    dead = false;
    // Synchronous again: a tail left rejected would swallow every later write.
    q.write("later");
    expect(writes).toEqual(["later"]);
  });
});

describe("padBareVerb", () => {
  it("pads a bare verb so Enter submits it literally", () => {
    expect(padBareVerb("/compact")).toBe("/compact ");
  });

  it("leaves anything that already clears the suggestion list alone", () => {
    expect(padBareVerb("/code-review --fix")).toBe("/code-review --fix");
    expect(padBareVerb("/review /etc/passwd")).toBe("/review /etc/passwd");
    expect(padBareVerb("ship it")).toBe("ship it");
    expect(padBareVerb("")).toBe("");
    expect(padBareVerb("x".repeat(400))).toBe("x".repeat(400));
  });
});
