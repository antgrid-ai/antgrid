import { existsSync } from "node:fs";
import { join } from "node:path";
import type { Detector, Candidate } from "./types";
import { envPort } from "./ports";

export const pythonDetector: Detector = {
  name: "python",
  async detect({ cwd }) {
    const hasManage = existsSync(join(cwd, "manage.py"));
    const hasPyproject = existsSync(join(cwd, "pyproject.toml"));
    const hasReqs = existsSync(join(cwd, "requirements.txt"));
    const hasPipfile = existsSync(join(cwd, "Pipfile"));
    if (!hasManage && !hasPyproject && !hasReqs && !hasPipfile) return null;

    const services: Candidate[] = [];
    const commands: Candidate[] = [];
    const ports: number[] = [];

    if (hasManage) {
      services.push({ kind: "service", name: "runserver", command: "python manage.py runserver", source: "manage.py" });
      commands.push(
        { kind: "command", name: "test",            command: "python manage.py test",            source: "manage.py" },
        { kind: "command", name: "migrate",         command: "python manage.py migrate",         source: "manage.py" },
        { kind: "command", name: "makemigrations",  command: "python manage.py makemigrations",  source: "manage.py" },
      );
      const envOverride = envPort(cwd);
      ports.push(envOverride ?? 8000);
    } else {
      commands.push({ kind: "command", name: "test", command: "pytest", source: "pyproject.toml" });
    }

    return { services, commands, skipped: [], ports };
  },
};
