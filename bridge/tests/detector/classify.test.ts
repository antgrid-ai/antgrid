import { describe, it, expect } from "bun:test";
import { classifyNpmScript } from "../../src/detector/classify";

describe("classifyNpmScript", () => {
  it("layer 1: name conventions", () => {
    expect(classifyNpmScript("dev", "node server.js")).toBe("service");
    expect(classifyNpmScript("start", "node server.js")).toBe("service");
    expect(classifyNpmScript("watch", "anything")).toBe("service");
    expect(classifyNpmScript("build:watch", "anything")).toBe("service");
    expect(classifyNpmScript("test", "jest")).toBe("command");
    expect(classifyNpmScript("build", "tsc")).toBe("command");
    expect(classifyNpmScript("lint", "eslint .")).toBe("command");
    expect(classifyNpmScript("deploy", "./scripts/deploy.sh")).toBe("command");
  });

  it("layer 2: content heuristics", () => {
    expect(classifyNpmScript("foo", "next dev")).toBe("service");
    expect(classifyNpmScript("foo", "vite")).toBe("service");
    expect(classifyNpmScript("foo", "nodemon app.js")).toBe("service");
    expect(classifyNpmScript("foo", "tsc --watch")).toBe("service");
    expect(classifyNpmScript("foo", "jest")).toBe("command");
    expect(classifyNpmScript("foo", "vitest run")).toBe("command");
    expect(classifyNpmScript("foo", "tsc --noEmit")).toBe("command");
  });

  it("&& chains classify by final command", () => {
    expect(classifyNpmScript("foo", "npm run build && npm run start")).toBe("service");
    expect(classifyNpmScript("foo", "pre-check && jest")).toBe("command");
  });

  it("returns 'unknown' when nothing matches", () => {
    expect(classifyNpmScript("generate", "graphql-codegen")).toBe("unknown");
  });
});
