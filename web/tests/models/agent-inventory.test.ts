import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestDevice } from "../helpers/fixtures.js";
import { listMobileEnabledAgents } from "../../src/models/agent-inventory.js";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

describe("listMobileEnabledAgents", () => {
  test("returns machineName", async () => {
    const user = await createTestUser(pg.db, "host@example.com");
    const deviceId = crypto.randomUUID();
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId,
      kind: "agent",
      platform: "macos",
      displayName: "Host Agent",
    });
    await pg.db.device.update({
      where: { userId_deviceId: { userId: user.id, deviceId } },
      data: { mobileAccessEnabled: true, machineName: "Mac Studio" },
    });

    const agents = await listMobileEnabledAgents(pg.db, user.id);
    expect(agents).toHaveLength(1);
    expect(agents[0].machineName).toBe("Mac Studio");
  });

  test("returns null machineName when unset", async () => {
    const user = await createTestUser(pg.db, "host2@example.com");
    const deviceId = crypto.randomUUID();
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId,
      kind: "agent",
      platform: "linux",
      displayName: "No-name Agent",
    });
    await pg.db.device.update({
      where: { userId_deviceId: { userId: user.id, deviceId } },
      data: { mobileAccessEnabled: true },
    });

    const agents = await listMobileEnabledAgents(pg.db, user.id);
    expect(agents).toHaveLength(1);
    expect(agents[0].machineName).toBeNull();
  });
});
