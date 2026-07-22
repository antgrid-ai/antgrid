import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Detector, Candidate } from "./types";
import { classifyNpmScript } from "./classify";

const TARGET_RE = /^([a-zA-Z0-9_\-.]+):(?!=)/;

export const makefileDetector: Detector = {
  name: "makefile",
  async detect({ cwd }) {
    const mk = join(cwd, "Makefile");
    if (!existsSync(mk)) return null;
    const content = readFileSync(mk, "utf8");

    const targets = new Set<string>();
    for (const line of content.split(/\r?\n/)) {
      if (line.startsWith("\t") || line.startsWith("#") || line.startsWith(".")) continue;
      const m = line.match(TARGET_RE);
      if (m && !["all", "default"].includes(m[1])) targets.add(m[1]);
    }

    const services: Candidate[] = [];
    const commands: Candidate[] = [];
    const skipped: { name: string; source: string }[] = [];

    for (const t of targets) {
      const kind = classifyNpmScript(t, t);
      const cand: Candidate = {
        kind: kind === "unknown" ? "command" : kind,
        name: t,
        command: `make ${t}`,
        source: `Makefile:${t}`,
      };
      if (kind === "service") services.push(cand);
      else if (kind === "command") commands.push(cand);
      else skipped.push({ name: t, source: cand.source });
    }

    return { services, commands, skipped, ports: [] };
  },
};
