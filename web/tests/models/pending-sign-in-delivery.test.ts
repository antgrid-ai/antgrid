import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createPending, markDelivery, findByIdWithHashes } from "../../src/models/pending-sign-in.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const SECRET = "delivery-test-secret";

describe("markDelivery", () => {
  test("records a hard bounce on the matching row", async () => {
    const row = await createPending(pg.db, {
      email: "a@example.com", nonce: "n", browserToken: "b",
      secret: SECRET, requesterUa: null, requesterIp: null,
    });
    const n = await markDelivery(pg.db, row.id, "bounced");
    expect(n).toBe(1);
    const after = await findByIdWithHashes(pg.db, row.id);
    expect(after?.deliveryStatus).toBe("bounced");
  });

  test("is a harmless no-op for an unknown or non-uuid reference", async () => {
    expect(await markDelivery(pg.db, "not-a-uuid", "bounced")).toBe(0);
    expect(await markDelivery(pg.db, "00000000-0000-0000-0000-000000000000", "bounced")).toBe(0);
  });
});
