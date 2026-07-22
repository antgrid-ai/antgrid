import { expect, test } from "bun:test";
import { licenseApiHostForTarget } from "./target-hosts.js";

test("desktop targets use localhost for the license API", () => {
  expect(licenseApiHostForTarget("windows", "192.168.31.222")).toBe(
    "localhost",
  );
  expect(licenseApiHostForTarget("macos", "192.168.31.222")).toBe("localhost");
});

test("Android retains the LAN host for the license API", () => {
  expect(licenseApiHostForTarget("android", "192.168.31.222")).toBe(
    "192.168.31.222",
  );
});

test("iOS retains the LAN host for the license API", () => {
  expect(licenseApiHostForTarget("ios", "192.168.31.222")).toBe(
    "192.168.31.222",
  );
});
