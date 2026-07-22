import { describe, it, expect, afterEach } from "bun:test";
import { stripInheritedCertOverrides } from "../src/terminal-session";

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
});
