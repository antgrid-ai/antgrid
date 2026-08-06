// The real-environment half of in-app self-update: what each agent's updater IS
// (derived from the registry) and the process spawns that drive it. The
// version math and the quiesce→update→restart orchestration are agent-agnostic
// and live in ./version; nothing in either file belongs to one agent.
//
// Fail-soft is the contract everywhere: a CLI installed by a package manager may
// refuse to self-update (exit non-zero, or no-op). We surface that output as a
// failed result and never try to interpret or repair the install.

import { resolveToolLaunchPath } from "../agents/launch-path";
import { AGENTS } from "../agents/registry";
import type { AgentUpdate } from "../agents/types";
import { createUpdateChecker, fetchNpmLatest } from "./version";

export { runAgentUpdate, parseAgentVersion, fetchNpmLatest } from "./version";

export interface ToolUpdateSpec extends AgentUpdate {
  // Canonical session.tool id. The SAME string flows the whole loop: detection →
  // agent:updateAvailable → app echo → agent:update → session filter → this
  // spec. It must match what SessionManager stamps on a session.
  tool: string;
}

// Only agents that ship a real self-updater, keyed by canonical session.tool id.
// github-copilot has none (IDE-bound) and so declares no `update` — a request
// for it fails soft via updateSpecFor → null.
//
// Derived from the registry, never hand-maintained: `tool` IS the registry key,
// so re-attaching it here is the only way the two can't drift.
export const TOOL_UPDATE_SPECS: Record<string, ToolUpdateSpec> = Object.fromEntries(
  Object.entries(AGENTS)
    .filter(([, spec]) => spec.update !== undefined)
    .map(([tool, spec]) => [tool, { tool, ...spec.update! }]),
);

export function updateSpecFor(tool: string): ToolUpdateSpec | null {
  return TOOL_UPDATE_SPECS[tool] ?? null;
}

// `<command> --version` on the resolved real binary. Fail-soft: "" on error.
export async function execToolVersion(
  spec: ToolUpdateSpec,
  path = process.env.PATH ?? process.env.Path,
): Promise<string> {
  const launch = resolveToolLaunchPath(spec.command, path);
  const proc = Bun.spawn([launch, "--version"], { stdout: "pipe", stderr: "ignore" });
  const out = await new Response(proc.stdout).text();
  await proc.exited;
  return out;
}

// `<command> <updateArgs...>` on the resolved real binary, capturing combined
// stdout+stderr and the exit code. The CLI's own updater stages/replaces itself;
// a non-zero exit (e.g. "installed via a package manager, update with …") is
// reported verbatim upstream — we never interpret or repair the install.
export async function execToolUpdate(
  spec: ToolUpdateSpec,
  path = process.env.PATH ?? process.env.Path,
): Promise<{ exitCode: number; output: string }> {
  const launch = resolveToolLaunchPath(spec.command, path);
  const proc = Bun.spawn([launch, ...spec.updateArgs], { stdout: "pipe", stderr: "pipe" });
  const [out, err, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { exitCode, output: (out + err).trim() };
}

// Proactive "a newer <tool> exists" checker for ANY agent in the table — the one
// seam every agent's detection flows through. An agent with a `readState`
// (codex's ~/.codex/version.json) gets a warm offline hint + an honored
// dismissed_version; the rest are npm-only with app-side dismissal. Shares one
// latest cache across a project's sessions and never throws.
export function createToolUpdateChecker(
  spec: ToolUpdateSpec,
): () => Promise<{ installed: string; latest: string } | null> {
  return createUpdateChecker({
    execVersion: () => execToolVersion(spec),
    fetchLatest: () => fetchNpmLatest(spec.npmPackage),
    readState: spec.readState,
  });
}
