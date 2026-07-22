import { describe, it, expect } from "bun:test";
import { createMessage, parseMessage, parseMessageFast } from "../src/protocol";

describe("file-upload protocol messages", () => {
  it("round-trips every upload message through full Zod validation", () => {
    const msgs = [
      createMessage("file:upload-start", {
        projectId: "p", requestId: "r1", fileName: "photo.png", size: 123, mimeType: "image/png",
      }),
      createMessage("file:upload-ready", { requestId: "r1", uploadId: "u1" }),
      createMessage("file:upload-chunk", { uploadId: "u1", seq: 0, data: "aGVsbG8=" }),
      createMessage("file:upload-ack", { uploadId: "u1", seq: 0 }),
      createMessage("file:upload-done", { uploadId: "u1" }),
      createMessage("file:upload-result", {
        requestId: "r1", uploadId: "u1", ok: true, path: "/abs/path/photo.png",
      }),
    ];
    for (const m of msgs) {
      const parsed = parseMessage(JSON.stringify(m));
      expect(parsed).not.toBeNull();
      expect(parsed!.type).toBe(m.type);
    }
  });

  it("error result carries code + human message", () => {
    const m = createMessage("file:upload-result", {
      requestId: "r1", ok: false, error: "TOO_LARGE", message: "File exceeds 20 MB limit",
    });
    const parsed = parseMessage(JSON.stringify(m));
    expect(parsed).not.toBeNull();
    if (parsed?.type === "file:upload-result") {
      expect(parsed.ok).toBe(false);
      expect(parsed.error).toBe("TOO_LARGE");
    }
  });

  it("rejects a chunk whose base64 data exceeds the wire cap", () => {
    const m = createMessage("file:upload-chunk", {
      uploadId: "u1", seq: 0, data: "A".repeat(768 * 1024 + 4),
    });
    expect(parseMessage(JSON.stringify(m))).toBeNull();
  });

  it("parseMessageFast knows all upload types (KNOWN_TYPES registration)", () => {
    for (const type of [
      "file:upload-start", "file:upload-ready", "file:upload-chunk",
      "file:upload-ack", "file:upload-done", "file:upload-result",
    ]) {
      const fast = parseMessageFast(JSON.stringify({ type, id: "x", timestamp: 1 }));
      expect(fast).not.toBeNull();
    }
  });
});
