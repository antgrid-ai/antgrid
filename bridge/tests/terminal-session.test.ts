import { describe, it, expect, afterEach } from "bun:test";
import { stripInheritedCertOverrides, isAntigravityBinary } from "../src/terminal-session";

const FLAG = "ANTGRID_STRIP_INHERITED_CERT_OVERRIDES";

afterEach(() => {
  delete process.env[FLAG];
});

describe("stripInheritedCertOverrides", () => {
  it("drops SSL_CERT_DIR/SSL_CERT_FILE when the dev flag is set", () => {
    process.env[FLAG] = "1";
    const out = stripInheritedCertOverrides({
      PATH: "/usr/bin",
      SSL_CERT_DIR: "C:\\Temp\\aspire-dcpx.tdr\\app\\certs",
      SSL_CERT_FILE: "/tmp/aspire-dcpx.tdr/app/certs/dev.pem",
    });
    expect(out.SSL_CERT_DIR).toBeUndefined();
    expect(out.SSL_CERT_FILE).toBeUndefined();
    expect(out.PATH).toBe("/usr/bin");
  });

  it("leaves the env untouched when the flag is absent (production)", () => {
    const input = {
      SSL_CERT_DIR: "/etc/ssl/certs",
      SSL_CERT_FILE: "/etc/ssl/cert.pem",
    };
    const out = stripInheritedCertOverrides(input);
    expect(out.SSL_CERT_DIR).toBe("/etc/ssl/certs");
    expect(out.SSL_CERT_FILE).toBe("/etc/ssl/cert.pem");
    // Returns the same object (no copy) on the no-op path.
    expect(out).toBe(input);
  });

  it("does not mutate the input object when stripping", () => {
    process.env[FLAG] = "1";
    const input = { SSL_CERT_DIR: "/tmp/aspire-dcpz.tdr/app/certs" };
    stripInheritedCertOverrides(input);
    expect(input.SSL_CERT_DIR).toBe("/tmp/aspire-dcpz.tdr/app/certs");
  });

  it("is a no-op for env without the cert vars even when flagged", () => {
    process.env[FLAG] = "1";
    const out = stripInheritedCertOverrides({ HOME: "/home/me" });
    expect(out).toEqual({ HOME: "/home/me" });
  });

  it("drops HTTP_PROXY/HTTPS_PROXY/ALL_PROXY (both cases) when the dev flag is set", () => {
    process.env[FLAG] = "1";
    const out = stripInheritedCertOverrides({
      PATH: "/usr/bin",
      HTTP_PROXY: "http://127.0.0.1:9999",
      HTTPS_PROXY: "http://127.0.0.1:9999",
      ALL_PROXY: "http://127.0.0.1:9999",
      http_proxy: "http://127.0.0.1:9999",
      https_proxy: "http://127.0.0.1:9999",
      all_proxy: "http://127.0.0.1:9999",
    });
    expect(out.HTTP_PROXY).toBeUndefined();
    expect(out.HTTPS_PROXY).toBeUndefined();
    expect(out.ALL_PROXY).toBeUndefined();
    expect(out.http_proxy).toBeUndefined();
    expect(out.https_proxy).toBeUndefined();
    expect(out.all_proxy).toBeUndefined();
    expect(out.PATH).toBe("/usr/bin");
  });

  it("leaves proxy vars untouched when the flag is absent (production)", () => {
    const input = { HTTPS_PROXY: "http://127.0.0.1:9999" };
    const out = stripInheritedCertOverrides(input);
    expect(out.HTTPS_PROXY).toBe("http://127.0.0.1:9999");
  });
});

describe("isAntigravityBinary", () => {
  it("matches the bare registry command", () => {
    expect(isAntigravityBinary("agy")).toBe(true);
  });

  it("matches the resolved Windows path, case-insensitively", () => {
    expect(isAntigravityBinary("C:\\Users\\welcome\\AppData\\Local\\agy\\bin\\agy.EXE")).toBe(true);
  });

  it("matches a forward-slash path", () => {
    expect(isAntigravityBinary("/home/me/.local/agy/bin/agy")).toBe(true);
  });

  it("does not match other agents or a substring match", () => {
    expect(isAntigravityBinary("claude")).toBe(false);
    expect(isAntigravityBinary("codex")).toBe(false);
    expect(isAntigravityBinary("agyx")).toBe(false);
    expect(isAntigravityBinary("not-agy")).toBe(false);
  });
});
