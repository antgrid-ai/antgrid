import { existsSync } from "node:fs";
import { join } from "node:path";
import type { Detector, Candidate } from "./types";

export const dockerDetector: Detector = {
  name: "docker",
  async detect({ cwd }) {
    const hasCompose = existsSync(join(cwd, "docker-compose.yml")) || existsSync(join(cwd, "compose.yaml"));
    const hasDockerfile = existsSync(join(cwd, "Dockerfile"));
    if (!hasCompose && !hasDockerfile) return null;

    const services: Candidate[] = [];
    const commands: Candidate[] = [];

    if (hasCompose) {
      services.push({ kind: "service", name: "compose", command: "docker compose up", source: "docker-compose.yml" });
      commands.push({ kind: "command", name: "compose-build", command: "docker compose build", source: "docker-compose.yml" });
    } else if (hasDockerfile) {
      commands.push({ kind: "command", name: "docker-build", command: "docker build .", source: "Dockerfile" });
    }

    return { services, commands, skipped: [], ports: [] };
  },
};
