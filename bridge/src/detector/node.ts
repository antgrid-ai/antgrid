import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import type { Detector, Candidate } from "./types";
import { classifyNpmScript } from "./classify";
import { inferFrameworkPort, envPort } from "./ports";

export const nodeDetector: Detector = {
  name: "node",
  async detect({ cwd }) {
    const pkgPath = join(cwd, "package.json");
    if (!existsSync(pkgPath)) return null;

    let pkg: any;
    try { pkg = JSON.parse(readFileSync(pkgPath, "utf8")); }
    catch { return null; }

    const scripts: Record<string, string> = pkg.scripts ?? {};
    const deps: Record<string, string> = { ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) };

    const services: Candidate[] = [];
    const commands: Candidate[] = [];
    const skipped: { name: string; source: string }[] = [];

    for (const [name, script] of Object.entries(scripts)) {
      const kind = classifyNpmScript(name, script);
      const source = `package.json:scripts.${name}`;
      if (kind === "service") {
        services.push({ kind: "service", name, command: `npm run ${name}`, source });
      } else if (kind === "command") {
        commands.push({ kind: "command", name, command: `npm run ${name}`, source });
      } else {
        skipped.push({ name, source });
      }
    }

    const ports: number[] = [];
    const envOverride = envPort(cwd);
    const fwPort = inferFrameworkPort(deps);
    if (envOverride !== null) ports.push(envOverride);
    else if (fwPort !== null) ports.push(fwPort);

    return { services, commands, skipped, ports };
  },
};
