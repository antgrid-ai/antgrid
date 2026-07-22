import type { AbConfig, PortConfig, CommandConfig } from "./config";
import { runDetectors } from "./detector";
import { NON_PREVIEW_PORTS } from "./detector/ports";
import { listKnownTools } from "./known-agents";
import { select, input, confirm } from "@inquirer/prompts";
import { stringify as stringifyYaml } from "yaml";
import { writeFileSync } from "node:fs";

export interface BootstrapIO {
  selectAgent(choices: string[]): Promise<string>;
  agentFlags(): Promise<string[]>;
  confirmCandidate(c: { kind: "service" | "command"; name: string; command: string }):
    Promise<{ kind: "service" | "command"; name: string; accept: "yes" | "no" | "flip" }>;
  confirmPort(port: number): Promise<{ port: number; accept: "yes" | "no" }>;
  confirmSave(): Promise<boolean>;
  log(line: string): void;
}

export interface BootstrapArgs {
  cwd: string;
  io: BootstrapIO;
}

export async function buildConfigFromBootstrap({ cwd, io }: BootstrapArgs): Promise<AbConfig> {
  const tool = await io.selectAgent([...listKnownTools(), "none"]);
  const flags = await io.agentFlags();

  const detected = await runDetectors(cwd);

  const commands: CommandConfig[] = [];

  // Services are temporarily disabled in `antgrid init`. Detected long-running
  // processes are surfaced as a notice only (not written to antgrid.yaml); the
  // services prompt loop + `cfg.services` scaffolding return with the feature.
  if (detected.services.length > 0) {
    io.log(`Detected ${detected.services.length} long-running process(es): ${detected.services.map((s) => s.name).join(", ")}`);
    io.log("(service support is temporarily unavailable — these were skipped)");
  }

  for (const c of detected.commands) {
    const ans = await io.confirmCandidate({ kind: "command", name: c.name, command: c.command });
    if (ans.accept === "yes") commands.push({ name: c.name, command: c.command });
  }

  if (detected.skipped.length > 0) {
    io.log(`Skipped ${detected.skipped.length} unrecognized scripts: ${detected.skipped.map((s) => s.name).join(", ")}`);
    io.log("(add manually to antgrid.yaml if needed)");
  }

  const ports: PortConfig[] = [];
  for (const p of detected.ports) {
    const ans = await io.confirmPort(p);
    if (ans.accept === "yes") ports.push({ port: p, onDetect: "notify" });
  }
  for (const p of NON_PREVIEW_PORTS) {
    ports.push({ port: p, onDetect: "ignore" });
  }

  const cfg: AbConfig = {};
  if (tool !== "none") cfg.agent = { tool, flags: flags.length > 0 ? flags : undefined };
  if (commands.length > 0) cfg.commands = commands;
  if (ports.length > 0)    cfg.ports = ports;
  return cfg;
}

export function consoleBootstrapIO(): BootstrapIO {
  return {
    async selectAgent(choices) {
      return await select({
        message: "Which coding agent?",
        choices: choices.map((c) => ({ value: c, name: c })),
      });
    },
    async agentFlags() {
      const raw = await input({ message: "Extra flags (space-separated, blank to skip):" });
      return raw.trim().length === 0 ? [] : raw.trim().split(/\s+/);
    },
    async confirmCandidate(c) {
      const ans = await select({
        message: `Command ${c.name} → ${c.command}`,
        choices: [
          { value: "yes", name: "Accept" },
          { value: "no",  name: "Skip" },
        ],
      });
      return { kind: c.kind, name: c.name, accept: ans as any };
    },
    async confirmPort(port) {
      const ans = await confirm({ message: `Include port ${port}?`, default: true });
      return { port, accept: ans ? "yes" : "no" };
    },
    async confirmSave() {
      return await confirm({ message: "Save this config to antgrid.yaml?", default: true });
    },
    log(line) { process.stdout.write(line + "\n"); },
  };
}

export function writeConfigYaml(path: string, cfg: AbConfig): void {
  writeFileSync(path, stringifyYaml(cfg), "utf8");
}
