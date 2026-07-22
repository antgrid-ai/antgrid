import { existsSync } from "node:fs";
import { join } from "node:path";
import type { Detector, Candidate } from "./types";

export const goDetector: Detector = {
  name: "go",
  async detect({ cwd }) {
    if (!existsSync(join(cwd, "go.mod"))) return null;
    const services: Candidate[] = [
      { kind: "service", name: "run", command: "go run .", source: "go.mod" },
    ];
    const commands: Candidate[] = [
      { kind: "command", name: "test",  command: "go test ./...",  source: "go.mod" },
      { kind: "command", name: "build", command: "go build ./...", source: "go.mod" },
      { kind: "command", name: "vet",   command: "go vet ./...",   source: "go.mod" },
    ];
    return { services, commands, skipped: [], ports: [] };
  },
};
