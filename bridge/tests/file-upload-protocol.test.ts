import { describe, it, expect } from "bun:test";
import {
  createMessage, parseMessage, parseMessageFast,
  CHECKOUT_VARIABLE_MESSAGE_TYPES,
} from "../src/protocol";

describe("file-upload protocol messages", () => {
  it("round-trips file:upload-local and file:upload-result through full Zod validation", () => {
    const msgs = [
      createMessage("file:upload-local", {
        projectId: "p", requestId: "r1", fileName: "photo.png", sourcePath: "/tmp/photo.png", mimeType: "image/png",
      }),
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

  it("parseMessageFast knows file:upload-local and file:upload-result (KNOWN_TYPES registration)", () => {
    for (const type of ["file:upload-local", "file:upload-result"]) {
      const fast = parseMessageFast(JSON.stringify({ type, id: "x", timestamp: 1 }));
      expect(fast).not.toBeNull();
    }
  });

  it("accepts INCOMPLETE as a result error code", () => {
    const m = createMessage("file:upload-result", {
      requestId: "r1", ok: false, error: "INCOMPLETE", message: "fewer bytes than declared",
    });
    const parsed = parseMessage(JSON.stringify(m));
    expect(parsed).not.toBeNull();
    if (parsed?.type === "file:upload-result") expect(parsed.error).toBe("INCOMPLETE");
  });

  it("file:upload-local is checkout-variable: it reads/writes a working tree, so its routing must resolve from the session's checkout", () => {
    expect(CHECKOUT_VARIABLE_MESSAGE_TYPES.has("file:upload-local")).toBe(true);
  });

  it("none of the five deleted socket-upload verbs parses any longer", () => {
    for (const type of ["file:upload-start", "file:upload-ready", "file:upload-chunk", "file:upload-ack", "file:upload-done"]) {
      const parsed = parseMessage(JSON.stringify({
        type, id: "x", timestamp: 1, projectId: "p", requestId: "r1", uploadId: "u1", seq: 0, data: "", fileName: "a", size: 1,
      }));
      expect(parsed).toBeNull();
    }
  });
});
