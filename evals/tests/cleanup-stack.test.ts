import { expect, test } from "bun:test";
import { CleanupStack } from "../helpers/harness";

test("cleanup stack runs every owner in reverse order and is idempotent", async () => {
  const seen: string[] = [];
  const cleanup = new CleanupStack();
  cleanup.add(() => { seen.push("first"); });
  cleanup.add(async () => { seen.push("second"); });
  cleanup.add(() => { seen.push("third"); });

  await cleanup.run();
  await cleanup.run();

  expect(seen).toEqual(["third", "second", "first"]);
});

test("cleanup stack continues after an owner fails", async () => {
  const seen: string[] = [];
  const cleanup = new CleanupStack();
  cleanup.add(() => { seen.push("survivor"); });
  cleanup.add(() => { throw new Error("cleanup failed"); });

  await expect(cleanup.run()).rejects.toThrow("cleanup failed");
  expect(seen).toEqual(["survivor"]);
});
