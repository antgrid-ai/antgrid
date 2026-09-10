import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  AbMessageSchema,
  BODY_REDACTED_MESSAGE_TYPES,
  CHECKOUT_VARIABLE_MESSAGE_TYPES,
  createMessage,
  parseMessage,
  parseMessageFast,
} from "../src/protocol";
import type { AbMessage } from "../src/protocol";

/** The text of one top-level `const NAME = ...;` declaration, so a registration
 *  assertion pins the block it means rather than any later occurrence. */
function sourceBlock(source: string, declaration: string): string {
  const start = source.indexOf(declaration);
  if (start < 0) throw new Error(`no declaration ${declaration}`);
  const end = source.indexOf("\n]);", start);
  if (end < 0) throw new Error(`unterminated declaration ${declaration}`);
  return source.slice(start, end);
}

const runId = "11111111-1111-4111-8111-111111111111";
const attachmentId = "22222222-2222-4222-8222-222222222222";
const requestId = "33333333-3333-4333-8333-333333333333";
const attachment = { terminalId: "t1", runId, attachmentId };

const screen = {
  version: 1 as const,
  revision: 7,
  cols: 80,
  rows: 24,
  ansi: "\x1b[H\x1b[2Jhello",
  syncTimedOut: false,
  history: { epoch: 0, firstRowId: 0, nextRowId: 12, status: "recording" as const },
};

const historyRow = {
  rowId: 4,
  cols: 80,
  wrapped: false,
  spans: [{ text: "hello", cells: 5, sgr: "\x1b[0m" }],
};

/** One entry per wire type: the schema const it is declared as, the exported
 *  `z.infer` alias, a payload `createMessage` accepts, and a mutation the schema
 *  must refuse. `malformed` is applied over a well-formed frame, so a rejection
 *  can only come from the field it changes. */
const CASES: ReadonlyArray<{
  type: AbMessage["type"];
  schemaConst: string;
  exportedType: string;
  payload: Record<string, unknown>;
  malformed: Record<string, unknown>;
}> = [
  {
    type: "terminal:subscribe",
    schemaConst: "TerminalSubscribeMessage",
    exportedType: "TerminalSubscribe",
    payload: { terminalId: "t1", version: 1, requestId },
    malformed: { requestId: "not-a-uuid" },
  },
  {
    type: "terminal:subscribed",
    schemaConst: "TerminalSubscribedMessage",
    exportedType: "TerminalSubscribed",
    payload: { ...attachment, version: 1, requestId },
    // The reply pins the version the bridge actually serves; anything else would
    // let a viewer believe a renderer it does not have was negotiated.
    malformed: { version: 2 },
  },
  {
    type: "terminal:frame",
    schemaConst: "TerminalFrameMessage",
    exportedType: "TerminalFrame",
    payload: { ...attachment, sequence: 0, ...screen },
    malformed: { cols: 1 },
  },
  {
    type: "terminal:ack",
    schemaConst: "TerminalAckMessage",
    exportedType: "TerminalAck",
    payload: { ...attachment, sequence: 3 },
    malformed: { sequence: -1 },
  },
  {
    type: "terminal:unsubscribe",
    schemaConst: "TerminalUnsubscribeMessage",
    exportedType: "TerminalUnsubscribe",
    payload: { ...attachment },
    malformed: { attachmentId: "" },
  },
  {
    type: "terminal:history:request",
    schemaConst: "TerminalHistoryRequestMessage",
    exportedType: "TerminalHistoryRequest",
    payload: { ...attachment, requestId, epoch: 0, beforeRowId: 40 },
    malformed: { beforeRowId: 1.5 },
  },
  {
    type: "terminal:history:page",
    schemaConst: "TerminalHistoryPageMessage",
    exportedType: "TerminalHistoryPage",
    payload: {
      ...attachment,
      requestId,
      history: screen.history,
      expired: false,
      beforeRowId: 40,
      rows: [historyRow],
    },
    malformed: { expired: "yes" },
  },
  {
    type: "terminal:display:status",
    schemaConst: "TerminalDisplayStatusMessage",
    exportedType: "TerminalDisplayStatus",
    payload: { terminalId: "t1", code: "UPGRADE_REQUIRED", message: "needs a newer app" },
    malformed: { code: "SOMETHING_ELSE" },
  },
];

describe("terminal frame wire contract", () => {
  for (const wire of CASES) {
    describe(wire.type, () => {
      test("is wired at every registration point in protocol.ts", () => {
        // Miss one and the type fails silently in a different way each time: it
        // parses but createMessage cannot build it, or it builds but every real
        // socket drops it. The fifth point in CLAUDE.md's checklist — the
        // dispatch `case` in agent-core.ts — applies only to the four inbound
        // types and is gated by the handler suite, so it is deliberately not
        // asserted here; this file gates the wire, not the handling.
        const protocol = readFileSync(join(import.meta.dir, "../src/protocol.ts"), "utf8");
        expect(protocol).toContain(`type: z.literal("${wire.type}")`);
        expect(sourceBlock(protocol, "export const AbMessageSchema"))
          .toContain(`${wire.schemaConst},`);
        expect(protocol).toContain(`export type ${wire.exportedType} =`);
        expect([...CHECKOUT_VARIABLE_MESSAGE_TYPES]).toContain(wire.type);
      });

      test("parses through the discriminated union", () => {
        const parsed = AbMessageSchema.safeParse(
          createMessage(wire.type, wire.payload as never),
        );
        expect(parsed.success).toBe(true);
      });

      test("survives parseMessageFast, the only check on the decrypted path", () => {
        // KNOWN_TYPES is not exported; parseMessageFast IS the membership test,
        // and it is the sole validation local-listener, relay-client and
        // stream-mux apply to an inbound frame. A type missing from the set is
        // dropped with no error in both directions.
        const raw = JSON.stringify(createMessage(wire.type, wire.payload as never));
        expect(parseMessageFast(raw)).toMatchObject({ type: wire.type });
      });

      test("defaults checkoutId to main and preserves an explicit one", () => {
        const built = createMessage(wire.type, wire.payload as never);
        expect(built).toMatchObject({ checkoutId: "main" });

        const explicit = parseMessage(JSON.stringify({ ...built, checkoutId: "checkout-2" }));
        expect(explicit).toMatchObject({ type: wire.type, checkoutId: "checkout-2" });
      });

      test("rejects a malformed payload", () => {
        const built = createMessage(wire.type, wire.payload as never);
        expect(parseMessage(JSON.stringify(built))).not.toBeNull();
        expect(parseMessage(JSON.stringify({ ...built, ...wire.malformed }))).toBeNull();
      });
    });
  }

  test("all eight types are checkout-scoped and none was forgotten", () => {
    expect(CASES.map((wire) => wire.type).sort()).toEqual([
      "terminal:ack", "terminal:display:status", "terminal:frame",
      "terminal:history:page", "terminal:history:request", "terminal:subscribe",
      "terminal:subscribed", "terminal:unsubscribe",
    ]);
  });

  test("rendered screen content is withheld from netwatch captures", () => {
    // Both carry the screen, which echoes whatever the user typed — the same
    // secret class terminal:input is redacted for. The four control frames carry
    // only ids and are left readable so a capture can still explain a session.
    expect([...BODY_REDACTED_MESSAGE_TYPES]).toContain("terminal:frame");
    expect([...BODY_REDACTED_MESSAGE_TYPES]).toContain("terminal:history:page");
    for (const type of ["terminal:subscribe", "terminal:subscribed", "terminal:ack", "terminal:unsubscribe"]) {
      expect([...BODY_REDACTED_MESSAGE_TYPES]).not.toContain(type);
    }
  });

  test("display status reports a failure that has no attachment yet", () => {
    // UPGRADE_REQUIRED answers a subscribe from an app the bridge cannot serve,
    // so no run and no attachment exist. Requiring either field would make the
    // one failure an old app can trigger unreportable.
    const parsed = parseMessage(JSON.stringify(createMessage("terminal:display:status", {
      terminalId: "t1", code: "UPGRADE_REQUIRED", message: "needs a newer app",
    })));
    expect(parsed).toMatchObject({ type: "terminal:display:status", code: "UPGRADE_REQUIRED" });
    expect(parsed && "runId" in parsed).toBe(false);

    const ended = parseMessage(JSON.stringify(createMessage("terminal:display:status", {
      ...attachment, code: "ENDED", message: "exited", finalSequence: 9, exitCode: 0,
    })));
    expect(ended).toMatchObject({ code: "ENDED", runId, finalSequence: 9, exitCode: 0 });
  });

  test("frame counters are not clamped to the in-flight budget", () => {
    // TERMINAL_VIEWER_MAX_FRAMES bounds how many frames may be UNACKED, not how
    // far the monotonic counters may run. A long-lived terminal legitimately
    // passes any of these numbers.
    const far = parseMessage(JSON.stringify(createMessage("terminal:frame", {
      ...attachment, sequence: 1_000_000, ...screen, revision: 5_000_000,
    })));
    expect(far).toMatchObject({ sequence: 1_000_000, revision: 5_000_000 });
  });

  test("an oversized history page is refused rather than truncated", () => {
    const built = createMessage("terminal:history:page", {
      ...attachment, requestId, history: screen.history, expired: false,
      beforeRowId: 40, rows: [historyRow],
    });
    const rows = Array.from({ length: 201 }, (_row, index) => ({ ...historyRow, rowId: index }));
    expect(parseMessage(JSON.stringify({ ...built, rows }))).toBeNull();
  });
});
