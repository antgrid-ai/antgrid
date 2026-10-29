import { appendFileSync, chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, delimiter, join, resolve } from "node:path";
import { createHash } from "node:crypto";
import { Database } from "bun:sqlite";
import { computeProjectId } from "../src/project-id";
import { createMessage } from "../src/protocol";

// This driver uses the desktop owner's authenticated transport. It never
// supplies an agent memory identity or changes the provider's prompt.
const reportPath = resolve(process.argv[2] ?? ".tmp/memory-qualification/agents.json");
const report = JSON.parse(readFileSync(reportPath, "utf8"));
const selected = (process.argv[3] ?? "claude,codex").split(",");
const previous = process.argv[4] ? JSON.parse(readFileSync(resolve(process.argv[4]), "utf8")) : undefined;
const providers = new Set(selected.map(selection => selection.split(":")[0]!.replace(/-tui$/, "")));
for (const provider of providers) {
  if (!["claude", "codex", "opencode"].includes(provider)) throw new Error(`Unknown agent ${provider}`);
  if (!report.capabilities[provider]?.binary) throw new Error(`Missing prepared ${provider} executable`);
}
const opencodeModel = report.capabilities.opencode?.model ?? undefined;
if (opencodeModel !== undefined && (typeof opencodeModel !== "string" || !/^[a-zA-Z0-9._:+-]+\/[a-zA-Z0-9._:/+-]+$/.test(opencodeModel))) {
  throw new Error("OpenCode model must be a provider/model identifier");
}
const runRoot = join(report.fixture_root, `live-${Date.now()}`);
mkdirSync(runRoot, { recursive: true });
const profile = previous?.profile ?? join(runRoot, "antgrid");
mkdirSync(profile, { recursive: true });
const project = previous?.project ?? join(runRoot, "non-git-work");
if (!previous) {
  mkdirSync(project);
  for (const name of ["shipping-guide.txt", "decision-notes.txt"]) copyFileSync(join(report.project, name), join(project, name));
  writeFileSync(join(project, "antgrid.yaml"), "name: Memory qualification\nservices: []\n");
}
const env: Record<string, string> = {};
for (const key of ["PATH", "Path", "SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP"]) {
  if (process.env[key]) env[key] = process.env[key]!;
}
const nativeRoot = previous ? dirname(previous.native_homes.codex ?? previous.native_homes.opencode ?? previous.native_homes.claude) : join(runRoot, "native-homes");
const nativeHomes = { claude: join(nativeRoot, "claude"), codex: join(nativeRoot, "codex"), opencode: join(nativeRoot, "opencode"), ...previous?.native_homes };
for (const agent of providers) {
  mkdirSync(nativeHomes[agent], { recursive: true });
  const name = agent === "claude" ? ".credentials.json" : agent === "opencode" ? join("data", "opencode", "auth.json") : "auth.json";
  if (!report.native_homes[agent]) throw new Error(`Missing prepared ${agent} native home`);
  const source = join(report.native_homes[agent], name);
  const target = join(nativeHomes[agent], name);
  if (existsSync(target)) continue;
  // Only explicitly authorized isolated auth sources are accepted by this
  // qualification driver; histories, configuration and memory never follow.
  if (!resolve(source).startsWith(resolve(report.fixture_root) + (process.platform === "win32" ? "\\" : "/"))) throw new Error("Authentication source must be inside the prepared isolated fixture");
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(source, target);
  if (process.platform === "win32") {
    const acl = Bun.spawnSync(["powershell.exe", "-NoProfile", "-Command", "Set-Acl -LiteralPath $env:MEMORY_AUTH_TARGET -AclObject (Get-Acl -LiteralPath $env:MEMORY_AUTH_SOURCE)"], {
      env: { ...env, MEMORY_AUTH_SOURCE: source, MEMORY_AUTH_TARGET: target }, stdout: "ignore", stderr: "pipe",
    });
    if (acl.exitCode !== 0) throw new Error("Could not preserve isolated credential permissions");
  } else chmodSync(target, 0o600);
}
Object.assign(env, {
  HOME: nativeRoot, USERPROFILE: nativeRoot,
  CLAUDE_CONFIG_DIR: nativeHomes.claude, CODEX_HOME: nativeHomes.codex,
  ANTGRID_DIR: profile,
});
if (providers.has("opencode")) {
  for (const [key, folder] of Object.entries({ XDG_DATA_HOME: "data", XDG_CONFIG_HOME: "config", XDG_STATE_HOME: "state", XDG_CACHE_HOME: "cache" })) {
    env[key] = join(nativeHomes.opencode, folder);
    mkdirSync(env[key]!, { recursive: true });
  }
}
env.PATH = [...providers].map(provider => dirname(report.capabilities[provider].binary)).concat(env.PATH ?? env.Path ?? "").join(delimiter);
delete env.Path;
const projectId = computeProjectId(project);
const hostLog = join(runRoot, "host.jsonl");
let apiPort: number | undefined;
let ws: WebSocket | undefined;
let control: { controlPort: number; token: string } | undefined;
const sessions = new Map<string, any>();
const exits = new Map<string, any>();
const output = new Map<string, string>();
const working = new Set<string>();
const workTransitions: { session_id: string; status: string; at: string }[] = [];
const pending = new Map<string, { resolve(value: any): void; reject(error: Error): void }>();
const observations: any[] = [];
const resultPath = join(runRoot, "results.json");
const saveReport = () => writeFileSync(resultPath, JSON.stringify({
  profile, project, project_id: projectId, platform: process.platform,
  native_homes: nativeHomes, capabilities: report.capabilities,
  mode: "terminal CLI through real Antgrid PTY", approval_policy: providers.has("opencode") ? "per-observation" : "bypass",
  app_controls: "authenticated desktop owner transport; Flutter UI not driven", resumed_from: process.argv[4], observations,
}, null, 2));
writeFileSync(join(dirname(reportPath), "current-live.json"), JSON.stringify({ run_root: runRoot, result: resultPath }, null, 2));
const host = Bun.spawn([process.execPath, resolve("bridge/src/index.ts")], {
  env, cwd: project, stdin: "pipe", stdout: "pipe", stderr: "pipe",
});
host.stdin.write(JSON.stringify({ ownerPid: process.pid, telemetryEnabled: false }) + "\n");
host.stdin.end();
const capture = async (stream: ReadableStream<Uint8Array>) => {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    const text = decoder.decode(value, { stream: true });
    appendFileSync(hostLog, text);
    const match = text.match(/API server listening on http:\/\/127\.0\.0\.1:(\d+)/);
    if (match) apiPort = Number(match[1]);
  }
};
const captures = [capture(host.stdout), capture(host.stderr)];
const waitUntil = async (predicate: () => boolean, timeout: number, label: string) => {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeout) throw new Error(`Timed out: ${label}`);
    await Bun.sleep(100);
  }
};
async function controlRequest(fields: object): Promise<any> {
  const response = await fetch(`http://127.0.0.1:${control!.controlPort}/control`, {
    method: "POST", headers: { authorization: `Bearer ${control!.token}`, "content-type": "application/json" },
    body: JSON.stringify({ id: crypto.randomUUID(), ...fields }),
  });
  const body = await response.json() as any;
  if (!body.ok) throw new Error(JSON.stringify(body.error));
  return body;
}
async function request(type: string, fields: Record<string, unknown> = {}): Promise<any> {
  const requestId = crypto.randomUUID();
  const response = new Promise<any>((resolve, reject) => pending.set(requestId, { resolve, reject }));
  const timer = setTimeout(() => { pending.get(requestId)?.reject(new Error(`${type} timed out`)); pending.delete(requestId); }, 20_000);
  ws!.send(JSON.stringify({ channel: "control", ...createMessage(type as any, { requestId, ...fields } as any) }));
  try { return await response; } finally { clearTimeout(timer); }
}
async function memory(request: Record<string, unknown>) {
  return (await controlRequest({ type: "memory:request", request })).result;
}
try {
  await waitUntil(() => existsSync(join(profile, "host.json")) || host.exitCode !== null, 30_000, "host startup");
  if (host.exitCode !== null) throw new Error(`Host exited ${host.exitCode}`);
  control = JSON.parse(readFileSync(join(profile, "host.json"), "utf8"));
  await memory({ op: "settings", enabled: true });
  const opened = await controlRequest({ type: "project:open", projectId, projectPath: project, mode: "local" });
  let ready = false;
  ws = new WebSocket(`ws://127.0.0.1:${opened.connect.port}`);
  ws.onopen = () => ws!.send(JSON.stringify({ type: "hello", token: opened.connect.token, appPid: process.pid }));
  ws.onmessage = (event) => {
    const message = JSON.parse(String(event.data));
    if (message.type === "ready") ready = true;
    if (message.type === "session:updated") for (const entry of message.sessions) {
      if (entry.workStatus && sessions.get(entry.id)?.workStatus !== entry.workStatus) workTransitions.push({ session_id: entry.id, status: entry.workStatus, at: new Date().toISOString() });
      if (entry.workStatus === "working") working.add(entry.id);
      sessions.set(entry.id, entry);
    }
    if (message.type === "terminal:exited") exits.set(message.terminalId, message);
    if (message.type === "terminal:output") output.set(message.terminalId, (output.get(message.terminalId) ?? "") + message.data);
    if (message.requestId && pending.has(message.requestId)) {
      pending.get(message.requestId)!.resolve(message); pending.delete(message.requestId);
    }
  };
  await waitUntil(() => ready, 20_000, "owner connection");
  for (const selection of selected) {
    const [agentMode, stage = "automatic_save", resumeSession] = selection.split(":");
    const interactive = agentMode === "codex-tui" || agentMode === "opencode-tui";
    const agent = interactive ? agentMode.slice(0, -"-tui".length) : agentMode;
    if (agent !== "claude" && agent !== "codex" && agent !== "opencode") throw new Error(`Unknown agent ${agent}`);
    if (agent === "opencode" && resumeSession) {
      const source = previous?.observations.find((row: any) => row.session_id === resumeSession);
      if (!interactive || source?.agent !== agent || source.mode !== "interactive terminal") {
        throw new Error("Resume OpenCode qualification with opencode-tui and a prior interactive terminal session");
      }
    }
    let scenario = report.scenarios.find((row: any) => row.id === stage);
    let replayCount: number | undefined;
    if (stage === "replay" || stage === "duplicate") {
      if (!resumeSession || !previous) throw new Error("Operation verification requires an original durable session and previous report");
      const source = previous.observations.find((row: any) => row.session_id === resumeSession);
      if (!source || source.agent !== agent) throw new Error("Replay session does not belong to this provider");
      const record = source.after.results.find((record: any) => record.source.session_id === resumeSession);
      if (!record) throw new Error("Replay has no saved original finding");
      const db = new Database(join(profile, "memory", "memory.sqlite"), { readonly: true });
      let keys: { operation_key: string }[];
      try {
        const owner = db.query("SELECT owner_id FROM profile").get() as { owner_id: string };
        const binding = createHash("sha256").update(JSON.stringify([owner.owner_id, "agent", projectId, resumeSession])).digest("hex");
        keys = stage === "duplicate" ? [{ operation_key: `qualification-duplicate-${crypto.randomUUID()}` }]
          : db.query("SELECT operation_key FROM operations WHERE binding=? AND state='suppressed'").all(binding) as { operation_key: string }[];
      } finally { db.close(); }
      if (!keys.length) throw new Error("No consumed operations exist for the original durable session");
      replayCount = keys.length;
      const save = { content: record.content, memory_type: record.memory_type, scope: record.scope, applicability: record.applicability ?? undefined, evidence: record.evidence };
      const scriptName = stage === "duplicate" ? "verify-duplicate-operation.ts" : "verify-forgotten-operation.ts";
      const scriptPath = join(project, scriptName);
      const script = `const operations = ${JSON.stringify(keys.map((key) => ({ ...key, save })))};\n`
        + `const port = process.env.ANTGRID_API_PORT; const terminal = process.env.ANTGRID_TERMINAL_ID; const run = process.env.ANTGRID_RUN_ID;\n`
        + `if (!port || !terminal || !run) throw new Error("Verified live terminal environment is missing");\n`
        + `for (const operation of operations) { const response = await fetch(\"http://127.0.0.1:\" + port + \"/memory/save?terminalId=\" + encodeURIComponent(terminal), { method: \"POST\", headers: { \"content-type\": \"application/json\" }, body: JSON.stringify({ ...operation, runId: run }) }); const result = await response.json(); console.log(JSON.stringify({ code: result.error?.code, status: response.status, outcome: result.outcome })); if (${stage === "duplicate" ? `result.outcome !== \"already_present\" || result.id !== ${JSON.stringify(record.id)}` : `result.error?.code !== \"FORGOTTEN\"`}) process.exitCode = 1; }\n`;
      writeFileSync(scriptPath, script);
      scenario = { prompt: `Run the local verification script ${scriptName} with Bun and report its result codes. Do not print environment variables or edit the script.` };
    }
    if (!scenario) throw new Error(`Unknown scenario ${stage}`);
    if (stage === "correction") copyFileSync(join(report.project, "correction.txt"), join(project, "correction.txt"));
    const name = `${agent}-${stage}-${Date.now()}`;
    const opencodeRun = agent === "opencode" && !interactive;
    const submitAfterResume = agent === "opencode" && interactive && !!resumeSession;
    if (submitAfterResume && /[\u0000-\u001f\u007f]/.test(scenario.prompt)) throw new Error("Resumed OpenCode qualification requires a single-line prompt without control keys");
    const approvalPolicy = agent === "opencode" ? "default" : "bypass";
    const modelArgs = agent === "opencode" && opencodeModel ? `--model ${opencodeModel}` : "";
    // `run` accepts a positional message; the production adapter's --prompt
    // belongs to the TUI. Raw Windows arguments expand percent variables, so
    // refuse such fixtures rather than silently changing their prompt.
    if (opencodeRun && /[%\r\n]/.test(scenario.prompt)) throw new Error("OpenCode run qualification requires a single-line prompt without percent expansion");
    const quotedPrompt = process.platform === "win32"
      ? `"${String(scenario.prompt).replace(/(\\*)"/g, "$1$1\\\"").replace(/(\\*)$/, "$1$1")}"`
      : `'${String(scenario.prompt).replace(/'/g, `'\\''`)}'`;
    const rawArgs = opencodeRun ? ["run --format json", modelArgs, quotedPrompt].filter(Boolean).join(" ")
      : interactive ? modelArgs : agent === "claude" ? "-p --output-format stream-json --verbose" : "exec --json --skip-git-repo-check";
    const created = resumeSession ? { ok: true, session: { id: resumeSession } } : await request("session:create", { name, tool: agent === "claude" ? "claude-code" : agent, args: rawArgs, mode: "terminal", approvalPolicy, isolation: "shared" });
    if (!created.ok) throw new Error(created.error);
    const sessionId = created.session.id;
    const before = await memory({ op: "list", versions: "all" });
    const start = Date.now();
    const row: any = { agent, mode: interactive ? "interactive terminal" : opencodeRun ? "terminal run" : "terminal print/exec", approval_policy: approvalPolicy, provider_version: report.capabilities[agent].version, configured_model: agent === "opencode" ? opencodeModel : undefined, native_database: agent === "opencode" ? join(nativeHomes.opencode, "data", "opencode", "opencode.db") : undefined, scenario: stage, session_id: sessionId, prompt: scenario.prompt, replayed_operations: replayCount, started_at: new Date(start).toISOString(), before };
    observations.push(row); saveReport();
    console.log(JSON.stringify({ event: "scenario_started", agent, scenario: stage, session_id: sessionId, run_root: runRoot }));
    exits.delete(sessionId);
    output.delete(sessionId);
    working.delete(sessionId);
    const started = await request("session:start", { sessionId, ...(opencodeRun || submitAfterResume ? {} : { initialPrompt: scenario.prompt }) });
    if (!started.ok) throw new Error(started.error);
    try {
      if (interactive) {
        let acceptedTrust = false;
        let submittedResumePrompt = false;
        let resumeReadySince: number | undefined;
        while (!exits.has(sessionId) && !(working.has(sessionId) && sessions.get(sessionId)?.workStatus === "done")) {
          if (Date.now() - start > 300_000) throw new Error("Timed out: interactive terminal turn completion");
          if (apiPort) {
            const response = await fetch(`http://127.0.0.1:${apiPort}/terminals/${sessionId}/scrollback?terminalId=${sessionId}`);
            if (response.ok) {
              const text = await response.text();
              writeFileSync(join(runRoot, "interactive-current.txt"), text);
              // OpenCode 1.19 consumes --prompt only on its home route; --session opens history.
              // https://github.com/anomalyco/opencode/blob/v1.19.0/packages/tui/src/routes/home.tsx
              const resumeReady = submitAfterResume && !working.has(sessionId)
                && text.includes("\u001b]0;OC |") && text.includes("Build") && text.includes("ctrl+p")
                && text.includes("commands") && text.includes("\u001b[?25h");
              resumeReadySince = resumeReady ? resumeReadySince ?? Date.now() : undefined;
              if (!submittedResumePrompt && resumeReadySince !== undefined && Date.now() - resumeReadySince >= 1000) {
                ws!.send(JSON.stringify({ channel: "control", ...createMessage("terminal:input", { terminalId: sessionId, checkoutId: "main", data: `${scenario.prompt}\r` }) }));
                submittedResumePrompt = true;
                row.startup_actions = [...(row.startup_actions ?? []), "Submitted the unchanged scenario prompt once through terminal input after the resumed OpenCode prompt was ready"];
                row.prompt_submitted_at = new Date().toISOString();
                row.prompt_delivery = "terminal input after native resume readiness";
                row.prompt_ready_stable_ms = Date.now() - resumeReadySince;
                saveReport();
              }
              if (agent === "codex" && !acceptedTrust && text.includes("Trust this folder?") && text.includes("Trust and continue")) {
                ws!.send(JSON.stringify({ channel: "control", ...createMessage("terminal:input", { terminalId: sessionId, checkoutId: "main", data: "\r" }) }));
                acceptedTrust = true;
                row.startup_actions = ["Accepted trust for the isolated fixture with Enter"];
                saveReport();
              }
            }
          }
          await Bun.sleep(500);
        }
        row.completion = working.has(sessionId) && sessions.get(sessionId)?.workStatus === "done" ? "hook work-status working to done" : "process exit";
        row.work_transitions = workTransitions.filter((entry) => entry.session_id === sessionId);
        row.stop_requested_after_completion = row.completion === "hook work-status working to done";
        await request("session:stop", { sessionId });
      }
      await waitUntil(() => exits.has(sessionId), interactive ? 20_000 : 300_000, `${agent} process exit`);
      row.exit = exits.get(sessionId);
    } catch (error) {
      row.failure = String(error);
      await request("session:stop", { sessionId });
    }
    row.latency_ms = Date.now() - start;
    row.finished_at = new Date().toISOString();
    row.session = sessions.get(sessionId);
    row.native_session_id = row.session?.agentSessionId;
    row.after = await memory({ op: "list", versions: "all" });
    let text = output.get(sessionId) ?? "";
    if (!text && apiPort) {
      const response = await fetch(`http://127.0.0.1:${apiPort}/terminals/${sessionId}/scrollback?terminalId=${sessionId}`);
      if (response.ok) text = await response.text();
    }
    row.output = join(runRoot, `${agent}-${stage}-${sessionId}.txt`);
    writeFileSync(row.output, text);
    saveReport();
    console.log(JSON.stringify({ event: "scenario_finished", agent, scenario: stage, session_id: sessionId, exit_code: row.exit?.exitCode, records_before: before.results.length, records_after: row.after.results.length, latency_ms: row.latency_ms, result: resultPath }));
    if (row.failure || (row.exit?.exitCode !== 0 && !row.stop_requested_after_completion)) break;
  }
} catch (error) {
  observations.push({ failure: String(error), at: new Date().toISOString() }); saveReport();
  console.error(String(error)); process.exitCode = 1;
} finally {
  ws?.close();
  if (control) try { await controlRequest({ type: "host:shutdown" }); } catch {}
  await Promise.race([host.exited, Bun.sleep(25_000)]);
  if (host.exitCode === null) host.kill();
  await host.exited;
  await Promise.all(captures);
  console.log(JSON.stringify({ event: "cleanup_complete", host_exit: host.exitCode, result: resultPath }));
}
