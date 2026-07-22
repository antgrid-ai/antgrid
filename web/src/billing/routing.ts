import type { ProviderId } from "./plans.js";

export function isProviderId(x: string | null | undefined): x is ProviderId {
  return x === "paddle" || x === "razorpay";
}

/** Paddle-blocked markets + IN + US → Razorpay (US always Razorpay per product decision). */
const RAZORPAY_COUNTRIES = new Set([
  "IN",
  "US",
  "RU",
  "BY",
  "IR",
  "KP",
  "SY",
  "CU",
  "VE",
  "AF",
  "MM",
  "CF",
  "CD",
  "HT",
  "IQ",
  "LY",
  "ML",
  "NI",
  "SO",
  "SS",
  "SD",
  "YE",
  "ZW",
]);

export function providerForCountry(countryCode: string | null | undefined): ProviderId {
  if (!countryCode) return "paddle";
  return RAZORPAY_COUNTRIES.has(countryCode.toUpperCase()) ? "razorpay" : "paddle";
}
