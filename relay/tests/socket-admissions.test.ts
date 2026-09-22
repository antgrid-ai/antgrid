import { describe, expect, test } from "bun:test";
import { SocketAdmissions } from "../src/socket-admissions";
import { connect, defaultConfig, startServer } from "./helpers/relay-harness";

describe("SocketAdmissions", () => {
  test("reserves global and per-IP capacity before authentication", () => {
    const admissions = new SocketAdmissions(2, 1);
    expect(admissions.reserve("a", "1.2.3.4")).toBeUndefined();
    expect(admissions.reserve("b", "1.2.3.4")).toBe("ip");
    expect(admissions.reserve("c", "5.6.7.8")).toBeUndefined();
    expect(admissions.reserve("d", "9.9.9.9")).toBe("global");
    expect(admissions.size).toBe(2);
  });

  test("releases each reservation exactly once", () => {
    const admissions = new SocketAdmissions(1, 1);
    expect(admissions.reserve("a", "1.2.3.4")).toBeUndefined();
    expect(admissions.release("a")).toBe(true);
    expect(admissions.release("a")).toBe(false);
    expect(admissions.size).toBe(0);
    expect(admissions.countForIp("1.2.3.4")).toBe(0);
    expect(admissions.reserve("b", "1.2.3.4")).toBeUndefined();
  });
});

test("unauthenticated upgraded sockets consume capacity until close", async () => {
  const relay = startServer({ ...defaultConfig, maxConnections: 1 });
  try {
    const held = await connect(relay);
    await expect(connect(relay)).rejects.toThrow();
    await new Promise<void>((resolve) => {
      held.onclose = () => resolve();
      held.close();
    });
    const replacement = await connect(relay);
    replacement.close();
  } finally {
    relay.stop();
  }
});
