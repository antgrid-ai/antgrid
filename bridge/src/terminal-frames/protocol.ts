import { z } from "zod";

// Payload sub-schemas and budgets for the frame display protocol. The eight
// WIRE ENVELOPES live in bridge/src/protocol.ts, which imports from here — so
// this file must never import from there, and must keep zod as its only import:
// protocol.ts is pulled in by nearly every module, and a cycle through it is
// expensive to unpick.

export const TERMINAL_PROTOCOL_VERSION = 1;
export const TERMINAL_FRAME_INTERVAL_MS = 50;
export const TERMINAL_VIEWER_MAX_FRAMES = 4;

/** Encoded size of a value as the transport will actually carry it. */
export const encodedJsonBytes = (value: unknown): number =>
  Buffer.byteLength(JSON.stringify(value));

/** The one display budget for a single `terminal:frame`, measured in
 *  ENCODED-JSON bytes. Every site — the schema bound, the capture cap and the
 *  sender's check — measures in this unit, because raw UTF-8 and JSON-encoded
 *  sizes disagree by up to 6x for exactly the content a frame carries:
 *  JSON.stringify renders each ESC (U+001B) as a six-byte backslash-u escape, and a
 *  serialized screen is dense with ESC. Mixing the units means a frame every
 *  producer accepts is rejected by the sender. */
export const TERMINAL_VIEWER_MAX_BYTES = 1024 * 1024;
/** In-flight ceiling across every attachment on one connection, same unit.
 *
 *  Equal to the per-attachment budget, not a multiple of it, and that is the
 *  point: frames ride the PREVIEW channel (see agent-core's `sendPreviewAb`
 *  wiring), whose credit window is `CHANNEL_WINDOW_BYTES` — 2 MiB in
 *  packages/antgrid-wire/src/flow.ts, which this file may not import (see the
 *  header). At 2 MiB a single terminal connection could hold the ENTIRE
 *  preview window un-acked for up to TERMINAL_ACK_TIMEOUT_MS, and the browser
 *  preview tunnel shares that window. Half the window still admits any single
 *  legal frame — a frame is capped at TERMINAL_VIEWER_MAX_BYTES — so lowering
 *  it costs only pipelining depth, which TERMINAL_VIEWER_MAX_FRAMES already
 *  bounds at four. */
export const TERMINAL_CONNECTION_MAX_BYTES = TERMINAL_VIEWER_MAX_BYTES;
/** Reserve for the frame envelope: ids, counters, geometry, the history
 *  boundary and JSON punctuation. Everything but `ansi` is bounded and small. */
const TERMINAL_FRAME_ENVELOPE_BYTES = 1024;
/** DERIVED from the budget above, and in the same unit — the largest
 *  JSON-encoded `ansi` a capture may produce and still leave room for its
 *  envelope. A capture over this is skipped for that frame alone; it is never a
 *  latch, because the next screen is independent and usually smaller. */
export const TERMINAL_FRAME_MAX_ANSI_BYTES =
  TERMINAL_VIEWER_MAX_BYTES - TERMINAL_FRAME_ENVELOPE_BYTES;

export const TERMINAL_ACK_TIMEOUT_MS = 10_000;
export const TERMINAL_HISTORY_PAGE_ROWS = 200;
export const TERMINAL_HISTORY_PAGE_BYTES = 256 * 1024;
export const TERMINAL_HISTORY_RUN_BYTES = 256 * 1024 * 1024;
export const TERMINAL_HISTORY_MACHINE_BYTES = 2 * 1024 * 1024 * 1024;

const counter = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const ansi = z.string().refine((value) => encodedJsonBytes(value) <= TERMINAL_FRAME_MAX_ANSI_BYTES);
export const TerminalHistoryBoundarySchema = z.object({
  epoch: counter,
  firstRowId: counter,
  nextRowId: counter,
  status: z.enum(["recording", "disabled"]),
});
export const TerminalHistorySpanSchema = z.object({
  text: z.string(),
  cells: counter,
  sgr: z.string().regex(/^\x1b\[[0-9;:]*m$/),
  uri: z.string().max(8192).regex(/^[^\x00-\x1f\x7f-\x9f]*$/).optional(),
});
export const TerminalHistoryRowSchema = z.object({
  rowId: counter,
  cols: z.number().int().min(2).max(1000),
  wrapped: z.boolean(),
  spans: z.array(TerminalHistorySpanSchema).max(1000),
});
export const TerminalScreenFrameSchema = z.object({
  version: z.literal(TERMINAL_PROTOCOL_VERSION),
  revision: counter,
  cols: z.number().int().min(2).max(1000),
  rows: z.number().int().min(1).max(500),
  ansi,
  syncTimedOut: z.boolean(),
  history: TerminalHistoryBoundarySchema,
});

export type TerminalScreenFrame = z.infer<typeof TerminalScreenFrameSchema>;
export type TerminalHistoryBoundary = z.infer<typeof TerminalHistoryBoundarySchema>;
export type TerminalHistoryRow = z.infer<typeof TerminalHistoryRowSchema>;
export type TerminalHistorySpan = z.infer<typeof TerminalHistorySpanSchema>;
