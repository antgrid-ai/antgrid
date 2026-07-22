// Launcher around `flutter run --machine` for the Aspire `app` resource.
//
// Why --machine: Aspire children have no TTY, so flutter's r/R/q hot-reload
// menu is dead, and raw VM-Service `reloadSources` fails for Flutter apps
// ("Error while starting Kernel isolate task") because the `flutter` tool —
// not the VM — owns the incremental compiler. The supported automation path
// is the Flutter daemon: `flutter run --machine` speaks JSON-RPC over
// stdin/stdout, and `app.restart {fullRestart:false}` performs a real hot
// reload through flutter's own compiler.
//
// This wrapper:
//   - spawns flutter in --machine mode and owns its stdin (so it can send
//     daemon requests — the apphost command process can't reach that stdin);
//   - translates daemon JSON events back into readable log lines for the
//     Aspire dashboard, and surfaces the VM Service URI;
//   - runs a localhost-only HTTP control server (POST /reload, /restart) and
//     writes its port to ANTGRID_FLUTTER_CONTROL so the dashboard "Hot reload"
//     command can trigger a reload.
//
// Invocation (from apphost.ts):
//   node flutter-launcher.mjs <flutterBin> run --machine -d windows [...]

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { createServer } from "node:http";
import { writeFileSync, rmSync } from "node:fs";

const flutterBin = process.argv[2];
const flutterArgs = process.argv.slice(3);
const controlFile = process.env.ANTGRID_FLUTTER_CONTROL;

if (!flutterBin) {
  console.error("[flutter-launcher] missing flutter binary argument");
  process.exit(2);
}

function clearControlFile() {
  if (!controlFile) return;
  try {
    rmSync(controlFile, { force: true });
  } catch {
    /* best effort */
  }
}

// A stale control file would point the command at a dead port — clear it now
// and re-publish once our server is listening.
clearControlFile();

// .bat shims (flutter.bat) can't be exec'd directly by spawn — they need a
// shell. Non-Windows runs the binary directly.
const child = spawn(flutterBin, flutterArgs, {
  stdio: ["pipe", "pipe", "pipe"],
  shell: process.platform === "win32",
});

let appId = null;
let nextId = 1;
const pending = new Map(); // request id -> { resolve }
const seenUnknownEvents = new Set(); // daemon event names already logged once

// Timeout for daemon requests. Kept below the apphost's fetch timeout so a
// wedged daemon surfaces as a clean "timed out" result before the HTTP call
// aborts. Also prevents the pending Map from leaking a never-resolved entry.
const DAEMON_TIMEOUT_MS = 55_000;

function sendDaemon(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      if (pending.delete(id)) {
        reject(new Error(`daemon ${method} timed out after ${DAEMON_TIMEOUT_MS}ms`));
      }
    }, DAEMON_TIMEOUT_MS);
    pending.set(id, (msg) => {
      clearTimeout(timer);
      resolve(msg);
    });
    child.stdin.write(`${JSON.stringify([{ id, method, params }])}\n`, (err) => {
      if (err) {
        clearTimeout(timer);
        pending.delete(id);
        reject(err);
      }
    });
  });
}

function log(line) {
  process.stdout.write(line.endsWith("\n") ? line : `${line}\n`);
}

// Engine-level diagnostics that should be flagged as errors in the dashboard.
const ENGINE_ERROR_LINE = /^\[(ERROR|FATAL)[:\]]/;

// Pass a non-daemon stdout line through. Engine-level diagnostics print
// straight to stdout (not as app.log events), e.g.
//   [ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception: ...
// Route ERROR/FATAL lines to stderr so the Aspire dashboard flags them.
function passthrough(line) {
  if (ENGINE_ERROR_LINE.test(line.trim())) {
    process.stderr.write(line.endsWith("\n") ? line : `${line}\n`);
  } else {
    log(line);
  }
}

function handleEvent(event, params) {
  switch (event) {
    case "app.start":
    case "app.started":
      if (params?.appId) appId = params.appId;
      if (event === "app.started") log("[flutter] app started — hot reload ready");
      break;
    case "app.debugPort":
      // wsUri is the VM Service WebSocket; surface the http form for parity
      // with non-machine output (and the Dart MCP / DevTools connect flow).
      if (params?.wsUri) {
        const httpUri = String(params.wsUri).replace(/^ws/, "http").replace(/\/ws$/, "/");
        log(`[flutter] Dart VM Service available at: ${httpUri}`);
      }
      break;
    case "app.dtd":
      // The Dart Tooling Daemon URI — what the Dart MCP server's
      // connect_dart_tooling_daemon tool (and DevTools) attach to. In
      // --machine mode flutter delivers it as this daemon event, NOT as the
      // plain `--print-dtd` stdout line, so we must surface it explicitly or
      // it's lost (`aspire logs app-windows --search "Tooling Daemon"`).
      if (params?.uri) log(`[flutter] Dart Tooling Daemon available at: ${params.uri}`);
      break;
    case "app.devTools":
      // DevTools URL (debugger/profiler/inspector in the browser).
      if (params?.uri) log(`[flutter] Flutter DevTools available at: ${params.uri}`);
      break;
    case "app.log":
      // App console output (print, FlutterError dumps, uncaught exceptions).
      // Route error logs to stderr so the Aspire dashboard flags them as
      // errors instead of plain output.
      if (params?.log != null) {
        (params.error ? process.stderr : process.stdout).write(String(params.log));
      }
      break;
    case "app.progress":
      if (params?.message && !params?.finished) log(`[flutter] ${params.message}`);
      break;
    case "daemon.logMessage":
      if (params?.message) log(`[flutter] ${params.message}`);
      break;
    case "daemon.showMessage":
      // Tool-level warnings/errors (not app output) — surface them, routing
      // error level to stderr so they aren't silently dropped.
      if (params?.message) {
        const level = params.level ?? "info";
        const text = `[flutter] ${level}: ${params.title ? `${params.title} — ` : ""}${params.message}`;
        (level === "error" ? process.stderr : process.stdout).write(`${text}\n`);
      }
      break;
    default:
      // Surface unrecognized daemon events once, so the next surprise (like
      // app.dtd was) isn't invisible.
      if (event && !seenUnknownEvents.has(event)) {
        seenUnknownEvents.add(event);
        log(`[flutter] (unhandled daemon event: ${event})`);
      }
      break;
  }
}

// flutter --machine emits one JSON array per line: [{...}]. Anything that
// isn't a daemon message (plain build/diagnostic output) is passed through.
const rl = createInterface({ input: child.stdout });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed.startsWith("[")) {
    if (trimmed.length > 0) passthrough(line);
    return;
  }
  let messages;
  try {
    messages = JSON.parse(trimmed);
  } catch {
    passthrough(line);
    return;
  }
  for (const msg of messages) {
    if (msg.event) {
      handleEvent(msg.event, msg.params);
    } else if (msg.id != null && pending.has(msg.id)) {
      const resolve = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg);
    }
  }
});

child.stderr.on("data", (c) => process.stderr.write(c));

async function appRestart(fullRestart) {
  const verb = fullRestart ? "Hot restart" : "Hot reload";
  if (!appId) {
    return { success: false, message: "App is still starting — try again in a moment." };
  }
  let resp;
  try {
    resp = await sendDaemon("app.restart", {
      appId,
      fullRestart,
      pause: false,
      reason: fullRestart ? "manual hot restart" : "manual hot reload",
    });
  } catch (err) {
    return { success: false, message: `failed to send daemon request: ${err}` };
  }
  if (resp.error) {
    const m = typeof resp.error === "string" ? resp.error : resp.error.message ?? JSON.stringify(resp.error);
    return { success: false, message: m };
  }
  const result = resp.result;
  if (result && result.code === 0) {
    return { success: true, message: result.message || `${verb} complete.` };
  }
  return { success: false, message: result?.message ?? `${verb} failed.` };
}

// Localhost-only control plane for the apphost "Hot reload" command.
const server = createServer((req, res) => {
  const sendJson = (obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(body);
  };
  if (req.method !== "POST") {
    res.writeHead(405);
    res.end();
    return;
  }
  if (req.url === "/reload") {
    appRestart(false).then(sendJson, (e) => sendJson({ success: false, message: String(e) }));
  } else if (req.url === "/restart") {
    appRestart(true).then(sendJson, (e) => sendJson({ success: false, message: String(e) }));
  } else {
    res.writeHead(404);
    res.end();
  }
});

server.listen(0, "127.0.0.1", () => {
  const addr = server.address();
  const port = typeof addr === "object" && addr ? addr.port : null;
  if (port && controlFile) {
    try {
      writeFileSync(controlFile, String(port), "utf8");
    } catch (err) {
      console.error(`[flutter-launcher] failed to write control file: ${err}`);
    }
  }
});

// Tear flutter down on shutdown. On Windows `child` is the cmd.exe shell
// (spawn shell:true), and killing it does NOT reap the flutter→dart→app
// subtree — leaving an orphaned antgrid.exe that holds the build's
// WebView2Loader.dll lock and breaks the next run. Use taskkill /T to kill
// the whole tree; elsewhere a direct signal to the (shell-less) child works.
let killed = false;
function killTree(sig) {
  if (killed || child.pid == null) return;
  killed = true;
  if (process.platform === "win32") {
    try {
      spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
    } catch {
      try {
        child.kill(sig);
      } catch {
        /* already gone */
      }
    }
  } else {
    try {
      child.kill(sig);
    } catch {
      /* already gone */
    }
  }
}

// Forward shutdown so Aspire's stop/restart tears flutter down.
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP", "SIGBREAK"]) {
  process.on(sig, () => killTree(sig));
}

child.on("exit", (code, signal) => {
  clearControlFile();
  try {
    server.close();
  } catch {
    /* ignore */
  }
  process.exit(code ?? (signal ? 1 : 0));
});

child.on("error", (err) => {
  console.error(`[flutter-launcher] failed to start flutter: ${err}`);
  process.exit(1);
});
