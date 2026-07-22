import { describe, it, expect } from "bun:test";
import { extractUrls, canonicalize } from "../src/url-parser";

describe("extractUrls", () => {
  it("finds http urls with port + path", () => {
    const hits = extractUrls("Local:   http://localhost:3000/foo");
    expect(hits).toEqual([
      { scheme: "http", host: "localhost", port: 3000, path: "/foo" },
    ]);
  });

  it("strips ANSI escape codes before matching", () => {
    const hits = extractUrls("\x1b[32mhttps://127.0.0.1:5173/\x1b[0m");
    expect(hits[0]).toEqual({ scheme: "https", host: "127.0.0.1", port: 5173, path: "/" });
  });

  it("finds multiple urls in one chunk (Vite Local + Network)", () => {
    const hits = extractUrls("Local:  http://localhost:5173/\nNetwork: http://192.168.1.10:5173/");
    expect(hits.length).toBe(2);
  });

  it("captures url without explicit port (defaults by scheme)", () => {
    const hits = extractUrls("Serving at https://localhost/");
    expect(hits[0]).toEqual({ scheme: "https", host: "localhost", port: 443, path: "/" });
  });
});

describe("canonicalize", () => {
  it("rewrites 0.0.0.0 and 127.0.0.1 to localhost", () => {
    expect(canonicalize({ scheme: "http", host: "127.0.0.1", port: 3000, path: "/" }).host).toBe("localhost");
    expect(canonicalize({ scheme: "http", host: "0.0.0.0",   port: 3000, path: "/" }).host).toBe("localhost");
  });
  it("leaves non-loopback hosts alone", () => {
    expect(canonicalize({ scheme: "http", host: "192.168.1.1", port: 3000, path: "/" }).host).toBe("192.168.1.1");
  });
});
