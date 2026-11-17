import { materializeAgentAssets } from "../src/plugin-root";
import { isDeepStrictEqual } from "node:util";
import * as memoryGuidance from "../assets/memory-guidance";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const directory = process.argv[2];
if (!directory) throw new Error("Pass an isolated asset directory");
const root = materializeAgentAssets(directory);
const guidance = await import(pathToFileURL(join(root, "memory-guidance.ts")).href);
for (const [name, value] of Object.entries(memoryGuidance)) {
  if (!isDeepStrictEqual(guidance[name], value)) throw new Error(`Materialized ${name} differs from compiled hooks`);
}
const plugin = await import(pathToFileURL(join(root, "opencode/plugin.ts")).href);
if (plugin.default?.id !== "antgrid" || typeof plugin.default.setup !== "function") throw new Error("V2 plugin definition missing");
const hooks: string[] = [];
const dispose = await plugin.default.setup({
  event: { subscribe: async function* () {} },
  session: { get: async () => ({}), hook: async (name: string) => { hooks.push(name); return { dispose: async () => {} }; } },
});
if (hooks.join() !== "context") throw new Error(`V2 plugin registered ${hooks.join() || "no"} session hooks`);
await dispose();
const kilo = await import(pathToFileURL(join(root, "kilo/plugin.ts")).href);
if (typeof (await kilo.AntgridSessionIdentity()).event !== "function") throw new Error("Kilo identity handler missing");
const env = { ...process.env };
delete env.ANTGRID_API_PORT;
delete env.ANTGRID_TERMINAL_ID;
delete env.ANTGRID_RUN_ID;
const proc = Bun.spawn(["node", join(root, "antigravity/post-title.js"), "PreInvocation"], {
  env, stdin: new Blob(["{}"]), stdout: "pipe", stderr: "pipe",
});
const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
if (code !== 0 || stdout.trim() !== "{}") throw new Error(`Node hook failed: ${code}: ${stderr}`);
console.log("Compiled assets loaded by Bun and Node outside the source tree");
