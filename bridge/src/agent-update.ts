// Tool-agnostic in-app self-update for the coding-agent CLIs.
//
// Codex proved the shape (detect a newer release; quiesce the machine-global
// binary, run the CLI's own updater once, restart the sessions). This layer is
// the single seam ALL tools flow through — codex included: the orchestration and
// version math live in ./codex/codex-version and are reused verbatim; only the
// binary, npm package, updater subcommand, and optional state file differ per
// tool, captured in each agent's `update` field in agents/registry.ts.
//
// Fail-soft is the contract everywhere: a CLI installed by a package manager may
// refuse to self-update (exit non-zero, or no-op). We surface that output as a
// failed result and never try to interpret or repair the install.

import {
  createCodexUpdateChecker,
  resolveToolLaunchPath,
  fetchNpmLatest,
  type CodexHomeState,
} from "./codex/codex-version";
import { AGENTS } from "./agents/registry";

// The generic quiesce→update→restart orchestrator is not codex-specific despite
// its name; re-export it under a tool-neutral alias for call sites that update
// any tool. Same for the single npm probe (one impl for every tool).
export { runCodexUpdate as runToolUpdate, fetchNpmLatest } from "./codex/codex-version";

export interface ToolUpdateSpec {
  // Canonical session.tool id. The SAME string flows the whole loop: detection →
  // agent:updateAvailable → app echo → agent:update → session filter → this
  // spec. It must match what SessionManager stamps on a session.
  tool: string;
  // npm package whose dist-tags.latest is the "latest" authority.
  npmPackage: string;
  // PATH binary name to resolve (realpath) for --version and the updater.
  command: string;
  // argv for the CLI's own self-updater (codex/claude `update`, opencode
  // `upgrade` — the divergence this table exists to record).
  updateArgs: string[];
  // Optional per-tool updater-state reader (codex's ~/.codex/version.json): a
  // free `latest_version` warm hint for offline detection and the
  // `dismissed_version` to honor. Tools without such a file omit it, and their
  // checker runs npm-only with app-side dismissal.
  readState?: () => CodexHomeState | null;
}

// Only tools that ship a real self-updater, keyed by canonical session.tool id.
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

// Proactive "a newer <tool> exists" checker for ANY tool in the table, codex
// included — the one seam every tool's detection flows through. A tool with a
// `readState` (codex's ~/.codex/version.json) gets a warm offline hint + an
// honored dismissed_version; the rest are npm-only with app-side dismissal.
// Shares one latest cache across a project's sessions and never throws.
export function createToolUpdateChecker(
  spec: ToolUpdateSpec,
): () => Promise<{ installed: string; latest: string } | null> {
  return createCodexUpdateChecker({
    execVersion: () => execToolVersion(spec),
    fetchLatest: () => fetchNpmLatest(spec.npmPackage),
    readState: spec.readState ?? (() => null),
  });
}
