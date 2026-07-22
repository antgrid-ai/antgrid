import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pythonDetector } from "../../src/detector/python";

describe("pythonDetector", () => {
  it("returns null without python markers", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    expect(await pythonDetector.detect({ cwd: dir })).toBeNull();
  });

  it("Django: manage.py runserver service + migrate/test commands, port 8000", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-py-"));
    writeFileSync(join(dir, "manage.py"), "# django\n", "utf8");
    writeFileSync(join(dir, "requirements.txt"), "django==5.0\n", "utf8");
    const r = await pythonDetector.detect({ cwd: dir });
    expect(r!.services.map((s) => s.command)).toContain("python manage.py runserver");
    expect(r!.commands.map((c) => c.command)).toEqual(
      expect.arrayContaining([
        "python manage.py test",
        "python manage.py migrate",
        "python manage.py makemigrations",
      ]),
    );
    expect(r!.ports).toContain(8000);
  });

  it("pyproject.toml only: pytest command, no service", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-py2-"));
    writeFileSync(join(dir, "pyproject.toml"), `[project]\nname = "x"\n`, "utf8");
    const r = await pythonDetector.detect({ cwd: dir });
    expect(r!.services.length).toBe(0);
    expect(r!.commands.map((c) => c.command)).toContain("pytest");
  });
});
