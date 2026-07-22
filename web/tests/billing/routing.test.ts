import { describe, test, expect } from "bun:test";
import { providerForCountry } from "../../src/billing/routing.js";

describe("providerForCountry", () => {
  test("IN and US route to razorpay", () => {
    expect(providerForCountry("IN")).toBe("razorpay");
    expect(providerForCountry("US")).toBe("razorpay");
  });

  test("Paddle-blocked countries route to razorpay", () => {
    expect(providerForCountry("RU")).toBe("razorpay");
  });

  test("other countries route to paddle", () => {
    expect(providerForCountry("DE")).toBe("paddle");
    expect(providerForCountry("GB")).toBe("paddle");
  });

  test("null defaults to paddle", () => {
    expect(providerForCountry(null)).toBe("paddle");
  });
});
