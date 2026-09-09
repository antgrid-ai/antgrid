import { describe, test, expect } from "bun:test";
import { formatTaskId, parseTaskId, TASK_ID_PREFIX } from "../../src/tasks/display-id.js";

describe("formatTaskId", () => {
  test("is the form a person reads", () => {
    expect(formatTaskId(14)).toBe(`${TASK_ID_PREFIX}-14`);
  });
});

describe("parseTaskId", () => {
  test("reads the bare number and the prefixed form alike", () => {
    expect(parseTaskId("14")).toBe(14);
    expect(parseTaskId("ANT-14")).toBe(14);
    expect(parseTaskId("ant-14")).toBe(14);
    expect(parseTaskId("  ANT-14  ")).toBe(14);
  });

  // The bound is the int4 column: an out-of-range literal has to miss here, or
  // Postgres raises where a 404 belongs.
  test("refuses anything that is not an in-range number", () => {
    for (const raw of [
      "",
      "0",
      "014",
      "-1",
      "14.0",
      "1234567890",
      "ANT-",
      "ANT-0",
      "ANT14",
      "OTHER-14",
      "ANT-14-1",
      "14; DROP TABLE tasks",
    ]) {
      expect(parseTaskId(raw)).toBeNull();
    }
  });
});
