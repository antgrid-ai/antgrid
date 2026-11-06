import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

// This preparation command never starts a model turn. Its fresh native homes
// prevent the qualification fixtures from entering a developer's own memory.
const args = process.argv.slice(2);
function argument(name: string): string | undefined {
  const index = args.indexOf(name);
  const value = index < 0 ? undefined : args[index + 1];
  return value?.startsWith("--") ? undefined : value;
}
const includeOpencode = args.includes("--opencode") || args.includes("--opencode-model");
const opencodeModel = argument("--opencode-model");
if (args.includes("--opencode-model") && (!opencodeModel || !/^[a-zA-Z0-9._:+-]+\/[a-zA-Z0-9._:/+-]+$/.test(opencodeModel))) {
  throw new Error("--opencode-model requires a provider/model identifier");
}
const output = resolve(argument("--output") ?? ".tmp/memory-qualification/agents.json");
const root = mkdtempSync(join(tmpdir(), "antgrid-memory-agents-"));
const project = join(root, "non-git-work");
const home = join(root, "home");
for (const directory of [project, home, join(home, "claude"), join(home, "codex")]) mkdirSync(directory, { recursive: true });

const fixtures = {
  "shipping-guide.txt": "The Lark archive exporter writes dates in UTC. When the Windows regional date format is dd/MM/yyyy, passing an ISO date string prevents day/month inversion. Verified fixture: exportDate=2026-04-03 -> archive date 2026-04-03. On macOS exporter 3.2, the ISO argument is rejected; use explicit --date-format yyyy-MM-dd instead. This is an internal fixture, not a claim about a real product.",
  "decision-notes.txt": "Proposal by Reviewer A: move the Lark archive exporter to a nightly schedule. No team approval has been recorded and no deployment has occurred.",
  "correction.txt": "New verification for Lark exporter 3.3 on Windows: ISO date strings are rejected. The supported method is --date-format yyyy-MM-dd with the requested date. This supersedes the prior Windows observation for version 3.3 only; older versions remain unverified.",
};
for (const [name, text] of Object.entries(fixtures)) writeFileSync(join(project, name), text);

const passthrough = ["PATH", "Path", "SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL"];
const env: Record<string, string> = {};
for (const name of passthrough) if (process.env[name]) env[name] = process.env[name]!;
Object.assign(env, { HOME: home, USERPROFILE: home, CLAUDE_CONFIG_DIR: join(home, "claude"), CODEX_HOME: join(home, "codex") });
const opencodeHome = join(home, "opencode");
const opencodeEnv: Record<string, string> = {};
if (includeOpencode) {
  for (const key of ["PATH", "Path", "SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP", "HOME", "USERPROFILE"]) {
    if (env[key]) opencodeEnv[key] = env[key]!;
  }
  for (const [key, folder] of Object.entries({ XDG_DATA_HOME: "data", XDG_CONFIG_HOME: "config", XDG_STATE_HOME: "state", XDG_CACHE_HOME: "cache" })) {
    opencodeEnv[key] = join(opencodeHome, folder);
    mkdirSync(opencodeEnv[key]!, { recursive: true });
  }
}

async function probe(binary: string | undefined, argv: string[], childEnv = env) {
  if (!binary) return { exit_code: null, stdout: "", stderr: "Executable not found" };
  let child;
  try {
    child = Bun.spawn([binary, ...argv], { cwd: project, env: childEnv, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  } catch {
    return { exit_code: null, stdout: "", stderr: "Executable could not be started" };
  }
  const timer = setTimeout(() => child.kill(), 10_000);
  try {
    const [stdout, stderr, exit_code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    return { exit_code, stdout, stderr };
  } finally { clearTimeout(timer); }
}

const claude = argument("--claude") ?? Bun.which("claude") ?? undefined;
const codex = argument("--codex") ?? Bun.which("codex") ?? undefined;
const opencode = includeOpencode ? argument("--opencode") ?? Bun.which("opencode") ?? undefined : undefined;
const [claudeVersion, codexVersion, claudeAuth, codexAuth, claudeHelp, codexHelp] = await Promise.all([
  probe(claude, ["--version"]), probe(codex, ["--version"]),
  probe(claude, ["auth", "status", "--json"]), probe(codex, ["login", "status"]),
  probe(claude, ["--help"]), probe(codex, ["exec", "--help"]),
]);
function claudeAuthenticated(): boolean | null {
  try {
    const value: unknown = JSON.parse(claudeAuth.stdout).loggedIn;
    return typeof value === "boolean" ? value : null;
  } catch { return null; }
}
const codexAuthText = `${codexAuth.stdout}\n${codexAuth.stderr}`;
const codexAuthenticated = /not logged in/i.test(codexAuthText) ? false
  : codexAuth.exit_code === 0 && /logged in/i.test(codexAuthText) ? true : null;
const capabilities = {
  claude: { binary: claude ?? null, version: claudeVersion.stdout.trim(), authenticated: claudeAuthenticated(), auth_status_exit_code: claudeAuth.exit_code },
  codex: { binary: codex ?? null, version: codexVersion.stdout.trim(), authenticated: codexAuthenticated, auth_status_exit_code: codexAuth.exit_code },
};
for (const [name, help] of [["claude", claudeHelp], ["codex", codexHelp]] as const) writeFileSync(join(root, `${name}-help.txt`), help.stdout);
let opencodeCapability: Record<string, unknown> | undefined;
if (includeOpencode) {
  const [version, help, runHelp, auth] = await Promise.all([
    probe(opencode, ["--version"], opencodeEnv),
    probe(opencode, ["--help"], opencodeEnv),
    probe(opencode, ["run", "--help"], opencodeEnv),
    probe(opencode, ["auth", "list"], opencodeEnv),
  ]);
  const authText = `${auth.stdout}\n${auth.stderr}`.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "");
  const count = authText.match(/\b(\d+)\s+credentials?\b/i)?.[1];
  opencodeCapability = {
    binary: opencode ?? null, version: version.stdout.trim(), model: opencodeModel ?? null,
    authenticated: null,
    credential_file_present: existsSync(join(opencodeHome, "data", "opencode", "auth.json")),
    configured_credential_count: count === undefined ? null : Number(count),
    auth_status_exit_code: auth.exit_code,
    auth_probe_scope: "Isolated native home metadata only; authentication requires a live qualification turn.",
  };
  writeFileSync(join(root, "opencode-help.txt"), help.stdout);
  writeFileSync(join(root, "opencode-run-help.txt"), runHelp.stdout);
}

const scenarios = [
  { id: "automatic_save", agent: "claude", session: "claude-finding", prompt: "Read shipping-guide.txt. Explain how to avoid the Lark archive export date bug on Windows, keeping the platform and version conditions clear. Verify the fixture evidence and report the result.", expected: "A useful Windows observation is saved without any remember request; incompatible macOS conditions remain distinct." },
  { id: "cross_agent_recall", agent: "codex", session: "codex-recall", prompt: "A previous agent investigated the Lark archive export date bug. Find its supported workaround and source conditions before recommending a Windows fix.", expected: "The other agent recalls the prior project finding on demand." },
  { id: "independent_repeat", agent: "codex", session: "codex-repeat", prompt: "Independently verify shipping-guide.txt and report the Windows export-date workaround and its conditions.", expected: "An exactly repeated finding does not create another eligible record; paraphrases are measured separately." },
  { id: "correction", agent: "claude", session: "claude-correction", prompt: "Read correction.txt, inspect the prior Windows finding, and correct it where the new evidence supersedes it. Keep version-specific uncertainty explicit.", expected: "Correction creates a new revision, leaves prior history inspectable, and cannot widen scope." },
  { id: "forget", agent: "codex", session: "codex-forget", prompt: "Forget the Antgrid project memory about the Lark archive export date workaround and its correction history.", expected: "Known save and duplicate operation replays cannot resurrect forgotten content." },
  { id: "proposal_attribution", agent: "claude", session: "claude-proposal", prompt: "Review decision-notes.txt and explain the current status of the proposed schedule change.", expected: "No claimed approval or implementation; missing evidence is preserved." },
  { id: "task_isolation", agent: "codex", session: "codex-isolation", prompt: "Summarize any unfinished work available to this new session about the export investigation.", expected: "No task-state memory from another durable session is disclosed." },
];
const report = {
  version: 1, generated_at: new Date().toISOString(), platform: process.platform,
  status: "not_run", reason: "Preparation only; no model calls were made.", fixture_root: root, project,
  native_homes: { claude: env.CLAUDE_CONFIG_DIR, codex: env.CODEX_HOME, ...(includeOpencode ? { opencode: opencodeHome } : {}) },
  capabilities: { ...capabilities, ...(opencodeCapability ? { opencode: opencodeCapability } : {}) },
  scenarios: scenarios.map(scenario => ({ ...scenario, status: "not_run", result: null,
    metrics: { save_misses: null, incorrect_saves: null, retrieval_misses: null, duplicate_records: null, extra_tool_calls: null, latency_ms: null, input_tokens: null, output_tokens: null, cost_usd: null } })),
};
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, JSON.stringify(report, null, 2));
console.log(JSON.stringify({ output, fixture_root: root, capabilities: report.capabilities, status: "not_run" }));
