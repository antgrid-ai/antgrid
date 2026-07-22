import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { flutterDetector } from "../../src/detector/flutter";

describe("flutterDetector", () => {
  it("returns null without pubspec.yaml", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    expect(await flutterDetector.detect({ cwd: dir })).toBeNull();
  });
  it("emits flutter run service and test/build/analyze commands", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-fl-"));
    writeFileSync(join(dir, "pubspec.yaml"), "name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n", "utf8");
    const r = await flutterDetector.detect({ cwd: dir });
    expect(r!.services.map((s) => s.command)).toContain("flutter run");
    expect(r!.commands.map((c) => c.command)).toEqual(
      expect.arrayContaining(["flutter test", "flutter build apk", "flutter analyze"]),
    );
  });
});
