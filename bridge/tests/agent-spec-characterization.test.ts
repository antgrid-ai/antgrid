// Bug-for-bug snapshot of every per-agent behavior, one case per (agent x
// concern), taken at the seams that survive the AgentSpec refactor. Later
// phases may rewrite this file's IMPORT lines as symbols move into
// agents/registry.ts; they must not change a single assertion. An assertion
// that has to change means the phase changed behavior.
//
// Assertions are on VALUES, never on which module exported a symbol, and never
// on an internal a phase deletes (buildPosts stays unexported; the raw
// TOOL_UPDATE_SPECS / KNOWN_AGENTS tables are read through their accessors).
//
// Every filesystem write is redirected into a fresh temp dir. Nothing here may
// touch the developer's real ~/.cursor, ~/.claude, ~/.codex or ~/.antgrid —
// same discipline as the Bun.main guard in cursor-agent's hooks.json write path.
import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { Database } from "bun:sqlite";

import { resumeArgv } from "../src/agent-resume";
import { initialPromptArgv } from "../src/initial-prompt";
import { updateSpecFor } from "../src/agent-update";
import { augmentAgentLaunch } from "../src/agent-launch-augmenter";
import { runHookInvocation, type HookPost } from "../src/hook-runner";
import { assembleContext } from "../src/handler/context";
import { type HookCommand } from "../src/hook-command";

/** Every registry key. A new agent must appear in every table below. */
const AGENT_KEYS = [
  "claude-code",
  "codex",
  "opencode",
  "cursor-agent",
  "github-copilot",
  "kilo",
  "kimi",
  "mistral-vibe",
] as const;
type AgentKey = (typeof AGENT_KEYS)[number];

/** Compile-time completeness: a table missing a key fails to typecheck. */
type PerAgent<T> = Record<AgentKey, T>;

// A POSIX-shaped, space-free binary keeps the rendered hook command identical
// in shape on both platforms, so the goldens below differ only in the quoting
// and call-operator rules they are meant to pin.
const BIN = "/opt/antgrid/antgrid-bridge";
const HOOK_COMMAND: HookCommand = { binary: BIN, preargs: ["hook"] };
const WIN = process.platform === "win32";

const tmpDirs: string[] = [];
function tmp(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tmpDirs.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of tmpDirs.splice(0)) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {}
  }
});

// ---------------------------------------------------------------------------
// Concern: resume argv
// ---------------------------------------------------------------------------

describe("resume argv", () => {
  const expected: PerAgent<string[]> = {
    "claude-code": ["--resume", "ID"],
    codex: ["resume", "ID"],
    opencode: ["--session", "ID"],
    "cursor-agent": ["--resume", "ID"],
    // Copilot's optional-value --resume drops a space-separated value.
    "github-copilot": ["--resume=ID"],
    kilo: [],
    kimi: [],
    "mistral-vibe": [],
  };

  for (const key of AGENT_KEYS) {
    test(key, () => {
      expect(resumeArgv(key, "ID")).toEqual(expected[key]);
    });
  }

  test("an unregistered tool starts fresh rather than throwing", () => {
    expect(resumeArgv("some-future-agent", "ID")).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Concern: initial prompt
// ---------------------------------------------------------------------------

describe("initial prompt argv", () => {
  const expected: PerAgent<string[]> = {
    "claude-code": ["--", "p"],
    codex: ["--", "p"],
    opencode: ["--prompt", "p"],
    "cursor-agent": ["--", "p"],
    "github-copilot": [],
    kilo: [],
    kimi: [],
    "mistral-vibe": [],
  };

  for (const key of AGENT_KEYS) {
    test(key, () => {
      expect(initialPromptArgv(key, "p")).toEqual(expected[key]);
    });
  }

  // The trim + blank guard is a SHARED pre-step, not per-agent: it runs before
  // the dispatch, so it holds even for agents that emit a prompt.
  for (const key of AGENT_KEYS) {
    test(`${key} emits nothing for a whitespace-only prompt`, () => {
      expect(initialPromptArgv(key, "  \n\t ")).toEqual([]);
    });
  }

  test("the emitted prompt is the trimmed one", () => {
    expect(initialPromptArgv("claude-code", "  fix it  ")).toEqual(["--", "fix it"]);
    expect(initialPromptArgv("opencode", "  fix it  ")).toEqual(["--prompt", "fix it"]);
  });
});

// ---------------------------------------------------------------------------
// Concern: codex hook trust
//
// computeCommandHookHash hashes the RENDERED command string, so any drift in
// how that string is built silently flips codex's hooks to Untrusted — no
// error, no log. These are full-literal goldens, not re-derivations through the
// producer, so a change to quoting, argv order, the "codex" hook name, the
// 600s timeout, or the state-key shape fails here.
// ---------------------------------------------------------------------------

const CODEX_INJECTION_WIN32: string[] = [
  "-c",
  'hooks.PermissionRequest=[{hooks=[{type="command",command="& \\"/opt/antgrid/antgrid-bridge\\" \\"hook\\" \\"codex\\" \\"permission-request\\""}]}]',
  "-c",
  'hooks.Stop=[{hooks=[{type="command",command="& \\"/opt/antgrid/antgrid-bridge\\" \\"hook\\" \\"codex\\" \\"stop\\""}]}]',
  "-c",
  'hooks.SessionStart=[{hooks=[{type="command",command="& \\"/opt/antgrid/antgrid-bridge\\" \\"hook\\" \\"codex\\" \\"session-start\\""}]}]',
  "-c",
  "hooks.state={'C:\\<session-flags>\\config.toml:permission_request:0:0'={trusted_hash=\"sha256:3e82f5650402783d2e3994646de6aa57c6a53e6d99de8fb9717643c32adde22d\"},'C:\\<session-flags>\\config.toml:stop:0:0'={trusted_hash=\"sha256:1d7caa27559a541b2c55656844ac9e3586b9d87f70873f623bb3b93bde490e94\"},'C:\\<session-flags>\\config.toml:session_start:0:0'={trusted_hash=\"sha256:61c27f2f55cc14d58631afd9d17d783e02066f5a4251859af01ff1779b5d21b3\"}}",
];

const CODEX_INJECTION_POSIX: string[] = [
  "-c",
  `hooks.PermissionRequest=[{hooks=[{type="command",command="'/opt/antgrid/antgrid-bridge' 'hook' 'codex' 'permission-request'"}]}]`,
  "-c",
  `hooks.Stop=[{hooks=[{type="command",command="'/opt/antgrid/antgrid-bridge' 'hook' 'codex' 'stop'"}]}]`,
  "-c",
  `hooks.SessionStart=[{hooks=[{type="command",command="'/opt/antgrid/antgrid-bridge' 'hook' 'codex' 'session-start'"}]}]`,
  "-c",
  `hooks.state={'/<session-flags>/config.toml:permission_request:0:0'={trusted_hash="sha256:46febd81962cdfcb8a0f1c7522cfd059863eb92dbd158f0d3ce2dc44baa44a95"},'/<session-flags>/config.toml:stop:0:0'={trusted_hash="sha256:d14f3ab0bb0201bcccdc987a0cbbf4418627d4f2bd725ed8be61ec81c8c65e9e"},'/<session-flags>/config.toml:session_start:0:0'={trusted_hash="sha256:ec29560fd4a6819f16dd77fe0e7a9d0507e66d8188c269e9fe6b70a64a070f3f"}}`,
];

const CODEX_INJECTION = WIN ? CODEX_INJECTION_WIN32 : CODEX_INJECTION_POSIX;
const CODEX_NOTIFY_ARG = `notify=["${BIN}","hook","codex","after-agent"]`;

describe("codex hook trust", () => {
  test("the -c hooks.state string is byte-for-byte stable", () => {
    const args = augmentAgentLaunch("codex", tmp("ab-spec-"), tmp("ab-cursor-"), HOOK_COMMAND).args;
    const state = args.find((a) => a.startsWith("hooks.state="));
    expect(state).toBe(CODEX_INJECTION[7]);
  });

  test("the three hook defs and their order are byte-for-byte stable", () => {
    const args = augmentAgentLaunch("codex", tmp("ab-spec-"), tmp("ab-cursor-"), HOOK_COMMAND).args;
    expect(args.slice(2)).toEqual(CODEX_INJECTION);
  });
});

// ---------------------------------------------------------------------------
// Concern: launch augmentation
// ---------------------------------------------------------------------------

describe("launch augmentation", () => {
  function augment(tool: string, abDir: string, cursorDir: string) {
    // OPENCODE_CONFIG set by the developer's own shell makes opencode a no-op;
    // clear it so the table describes the bridge's behavior, not the host's.
    const prev = process.env.OPENCODE_CONFIG;
    delete process.env.OPENCODE_CONFIG;
    try {
      return augmentAgentLaunch(tool, abDir, cursorDir, HOOK_COMMAND);
    } finally {
      if (prev !== undefined) process.env.OPENCODE_CONFIG = prev;
    }
  }

  test("claude-code", () => {
    const abDir = tmp("ab-spec-");
    const a = augment("claude-code", abDir, tmp("ab-cursor-"));
    expect(a.args).toEqual(["--plugin-dir", join(abDir, "plugin", "claude")]);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBe(true);
  });

  test("codex", () => {
    const a = augment("codex", tmp("ab-spec-"), tmp("ab-cursor-"));
    expect(a.args).toEqual(["-c", CODEX_NOTIFY_ARG, ...CODEX_INJECTION]);
    expect(a.env).toEqual({});
    // Codex reports no outcome; session-manager reads undefined as success.
    expect(a.notificationsInjected).toBeUndefined();
  });

  test("opencode", () => {
    const abDir = tmp("ab-spec-");
    const a = augment("opencode", abDir, tmp("ab-cursor-"));
    expect(a.args).toEqual([]);
    expect(a.env).toEqual({
      OPENCODE_CONFIG: join(abDir, "agents", "opencode-session-namer.json"),
    });
    expect(a.notificationsInjected).toBeUndefined();
  });

  test("opencode yields to a user-set OPENCODE_CONFIG", () => {
    const prev = process.env.OPENCODE_CONFIG;
    process.env.OPENCODE_CONFIG = "/user/own.json";
    try {
      expect(
        augmentAgentLaunch("opencode", tmp("ab-spec-"), tmp("ab-cursor-"), HOOK_COMMAND),
      ).toEqual({ args: [], env: {} });
    } finally {
      if (prev === undefined) delete process.env.OPENCODE_CONFIG;
      else process.env.OPENCODE_CONFIG = prev;
    }
  });

  test("cursor-agent", () => {
    const cursorDir = tmp("ab-cursor-");
    const a = augment("cursor-agent", tmp("ab-spec-"), cursorDir);
    expect(a.args).toEqual(["--trust"]);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBe(true);
  });

  test("cursor-agent keeps --trust but reports failure when the hooks file cannot be written", () => {
    const notADir = join(tmp("ab-cursor-"), "not-a-dir");
    writeFileSync(notADir, "");
    expect(augmentAgentLaunch("cursor-agent", tmp("ab-spec-"), notADir, HOOK_COMMAND)).toEqual({
      args: ["--trust"],
      env: {},
      notificationsInjected: false,
    });
  });

  test("github-copilot", () => {
    const abDir = tmp("ab-spec-");
    const a = augment("github-copilot", abDir, tmp("ab-cursor-"));
    expect(a.args).toEqual(["--plugin-dir", join(abDir, "plugin", "copilot")]);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBeUndefined();
  });

  for (const key of ["kilo", "kimi", "mistral-vibe"] as const) {
    test(`${key} has no launch injection`, () => {
      expect(augment(key, tmp("ab-spec-"), tmp("ab-cursor-"))).toEqual({ args: [], env: {} });
    });
  }

  test("an unregistered tool has no launch injection", () => {
    expect(augment("some-future-agent", tmp("ab-spec-"), tmp("ab-cursor-"))).toEqual({
      args: [],
      env: {},
    });
  });

  test("claude-code falls back to OSC when materialization fails", () => {
    const notADir = join(tmp("ab-spec-"), "not-a-dir");
    writeFileSync(notADir, "");
    expect(augmentAgentLaunch("claude-code", notADir, tmp("ab-cursor-"), HOOK_COMMAND)).toEqual({
      args: [],
      env: {},
      notificationsInjected: false,
    });
  });
});

// ---------------------------------------------------------------------------
// Concern: materialized files
//
// The on-disk bytes are the real contract with each agent's plugin loader: the
// augmentation return value only says WHERE, the file says WHAT.
// ---------------------------------------------------------------------------

/** How each agent's own loader is told to invoke `bridge hook <name> <event>`. */
const shellHook = (agent: string, event: string) =>
  WIN
    ? `& "${BIN}" "hook" "${agent}" "${event}"`
    : `'${BIN}' 'hook' '${agent}' '${event}'`;

/** Cursor tokenizes the string into argv itself: double quotes, no `&`, both platforms. */
const cursorHook = (event: string) => `"${BIN}" "hook" "cursor" "${event}"`;

const pretty = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`;

describe("materialized files", () => {
  test("claude-code writes a plugin manifest and one command hook per event", () => {
    const abDir = tmp("ab-spec-");
    augmentAgentLaunch("claude-code", abDir, tmp("ab-cursor-"), HOOK_COMMAND);
    const root = join(abDir, "plugin", "claude");

    expect(readFileSync(join(root, ".claude-plugin", "plugin.json"), "utf8")).toBe(
      pretty({
        name: "antgrid-session-namer",
        version: "0.1.0",
        description: "Reports agent lifecycle events to the Antgrid bridge.",
      }),
    );

    const hook = (event: string) => ({
      type: "command",
      command: BIN,
      args: ["hook", "claude", event],
      timeout: 5,
    });
    expect(readFileSync(join(root, "hooks", "hooks.json"), "utf8")).toBe(
      pretty({
        hooks: {
          SessionStart: [{ hooks: [hook("session-start")] }],
          Stop: [{ hooks: [hook("stop")] }],
          Notification: [{ hooks: [hook("notification")] }],
          UserPromptSubmit: [{ hooks: [hook("user-prompt")] }],
        },
      }),
    );
  });

  test("github-copilot writes one manifest carrying both shell hooks", () => {
    const abDir = tmp("ab-spec-");
    augmentAgentLaunch("github-copilot", abDir, tmp("ab-cursor-"), HOOK_COMMAND);
    expect(readFileSync(join(abDir, "plugin", "copilot", "plugin.json"), "utf8")).toBe(
      pretty({
        name: "antgrid-copilot",
        version: "0.1.0",
        description: "Antgrid bundled GitHub Copilot plugin",
        hooks: {
          sessionStart: [
            { type: "command", command: shellHook("github-copilot", "session-start"), timeoutSec: 5 },
          ],
          agentStop: [
            { type: "command", command: shellHook("github-copilot", "agent-stop"), timeoutSec: 5 },
          ],
        },
      }),
    );
  });

  test("cursor-agent merges two managed entries into the global hooks file", () => {
    const cursorDir = tmp("ab-cursor-");
    augmentAgentLaunch("cursor-agent", tmp("ab-spec-"), cursorDir, HOOK_COMMAND);
    expect(readFileSync(join(cursorDir, "hooks.json"), "utf8")).toBe(
      pretty({
        hooks: {
          sessionStart: [{ command: cursorHook("session-start"), timeout: 5 }],
          stop: [{ command: cursorHook("stop"), timeout: 5 }],
        },
        version: 1,
      }),
    );
  });

  test("opencode points its config at the plugin bundled under bridge/plugin", () => {
    // Anchored on this test file, NOT on whichever src/ module writes it: the
    // bundled asset lives at bridge/plugin/opencode/plugin.ts and a producer
    // that resolves it relative to a moved source dir writes a config opencode
    // silently never loads.
    const expectedUrl = pathToFileURL(
      join(import.meta.dir, "..", "plugin", "opencode", "plugin.ts"),
    ).href;
    const abDir = tmp("ab-spec-");
    const prev = process.env.OPENCODE_CONFIG;
    delete process.env.OPENCODE_CONFIG;
    try {
      augmentAgentLaunch("opencode", abDir, tmp("ab-cursor-"), HOOK_COMMAND);
    } finally {
      if (prev !== undefined) process.env.OPENCODE_CONFIG = prev;
    }
    // No trailing newline here — this writer stringifies without one.
    expect(readFileSync(join(abDir, "agents", "opencode-session-namer.json"), "utf8")).toBe(
      JSON.stringify({ plugin: [expectedUrl] }, null, 2),
    );
  });

  for (const key of ["codex", "kilo", "kimi", "mistral-vibe"] as const) {
    test(`${key} materializes nothing`, () => {
      const abDir = tmp("ab-spec-");
      augmentAgentLaunch(key, abDir, tmp("ab-cursor-"), HOOK_COMMAND);
      expect(readdirSync(abDir)).toEqual([]);
    });
  }
});

// ---------------------------------------------------------------------------
// Concern: hook posts
//
// Driven through runHookInvocation with injected HookRunnerDeps — buildPosts is
// unexported and must stay so. Agents are addressed by their HOOK name, which
// is a second vocabulary from the registry key; the mapping is pinned here.
// ---------------------------------------------------------------------------

const PORT = 43123;
const TERM = "term-1";

async function hookPosts(opts: {
  agent: string;
  event: string;
  stdin?: string;
  payload?: string;
  env?: Record<string, string | undefined>;
  files?: Record<string, string>;
}): Promise<HookPost[]> {
  const posts: HookPost[] = [];
  await runHookInvocation(
    { agent: opts.agent, event: opts.event, payload: opts.payload },
    {
      env: { ANTGRID_API_PORT: String(PORT), ANTGRID_TERMINAL_ID: TERM, ...opts.env },
      readStdin: async () => opts.stdin ?? "",
      readFile: (path) => {
        const value = opts.files?.[path];
        if (value === undefined) throw new Error("missing");
        return value;
      },
      post: async (post) => {
        posts.push(post);
      },
    },
  );
  return posts;
}

/** hookName per registry key; null = this agent never runs `bridge hook`. */
const HOOK_NAME: PerAgent<string | null> = {
  "claude-code": "claude",
  codex: "codex",
  // opencode's plugin posts to the loopback API from inside opencode's own
  // runtime, so it has an agent wire name but no hook-runner name.
  opencode: null,
  "cursor-agent": "cursor",
  "github-copilot": "github-copilot",
  kilo: null,
  kimi: null,
  "mistral-vibe": null,
};

describe("hook posts", () => {
  describe("claude-code (hook name: claude)", () => {
    const name = HOOK_NAME["claude-code"]!;

    test("session-start posts a title with the transcript path", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "session-start",
        stdin: JSON.stringify({ session_id: "s1", transcript_path: "/tmp/t.jsonl" }),
      });
      expect(posts).toEqual([
        {
          port: PORT,
          path: "/session-title",
          body: { terminalId: TERM, sessionId: "s1", agent: "claude", transcriptPath: "/tmp/t.jsonl" },
        },
      ]);
    });

    test("stop posts title, notify, and handler-event in that order", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "stop",
        stdin: JSON.stringify({ session_id: "s2", transcript_path: "/tmp/stop.jsonl" }),
      });
      expect(posts).toEqual([
        {
          port: PORT,
          path: "/session-title",
          body: { terminalId: TERM, sessionId: "s2", agent: "claude", transcriptPath: "/tmp/stop.jsonl" },
        },
        {
          port: PORT,
          path: "/notify",
          body: {
            type: "task_complete",
            agent: "claude",
            terminalId: TERM,
            transcriptPath: "/tmp/stop.jsonl",
          },
        },
        {
          port: PORT,
          path: "/handler-event",
          body: {
            terminalId: TERM,
            agent: "claude",
            event: "turn_end",
            transcriptPath: "/tmp/stop.jsonl",
            sessionId: "s2",
          },
        },
      ]);
    });

    test("stop coerces a null transcript on the title and handler posts, omits it on notify", async () => {
      // The asymmetry is deliberate and load-bearing: /notify spreads the key
      // away, /session-title and /handler-event send "".
      const posts = await hookPosts({
        agent: name,
        event: "stop",
        stdin: JSON.stringify({ session_id: "s4", transcript_path: null }),
      });
      expect(posts.map((p) => p.body)).toEqual([
        { terminalId: TERM, sessionId: "s4", agent: "claude", transcriptPath: "" },
        { type: "task_complete", agent: "claude", terminalId: TERM },
        { terminalId: TERM, agent: "claude", event: "turn_end", transcriptPath: "", sessionId: "s4" },
      ]);
    });

    test("user-prompt posts only a turn-start", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "user-prompt",
        stdin: JSON.stringify({ session_id: "s1", prompt: "hi" }),
      });
      expect(posts).toEqual([{ port: PORT, path: "/turn-start", body: { terminalId: TERM } }]);
    });

    test("a non-waiting notification is a permission_request", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "notification",
        stdin: JSON.stringify({ message: "Claude needs permission", session_id: "s3", transcript_path: "/t" }),
      });
      expect(posts).toEqual([
        {
          port: PORT,
          path: "/handler-event",
          body: {
            terminalId: TERM,
            agent: "claude",
            event: "awaiting_input",
            transcriptPath: "/t",
            sessionId: "s3",
          },
        },
        {
          port: PORT,
          path: "/notify",
          body: { type: "permission_request", terminalId: TERM, message: "Claude needs permission" },
        },
      ]);
    });

    test("a /waiting/i notification is awaiting_input, but the handler event never is", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "notification",
        stdin: JSON.stringify({ message: "Claude is WAITING for your input" }),
      });
      expect(posts.map((p) => p.body)).toEqual([
        { terminalId: TERM, agent: "claude", event: "awaiting_input", transcriptPath: "", sessionId: "" },
        { type: "awaiting_input", terminalId: TERM, message: "Claude is WAITING for your input" },
      ]);
    });

    test("an event outside the allowlist posts nothing", async () => {
      expect(await hookPosts({ agent: name, event: "agent-stop", stdin: "{}" })).toEqual([]);
    });
  });

  describe("codex (hook name: codex)", () => {
    const name = HOOK_NAME.codex!;

    test("after-agent reads the ARGV payload and posts title plus turn-end", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "after-agent",
        payload: JSON.stringify({ "thread-id": "thread-1" }),
      });
      expect(posts).toEqual([
        // No transcriptPath key at all: codex has no followable transcript here.
        { port: PORT, path: "/session-title", body: { terminalId: TERM, sessionId: "thread-1", agent: "codex" } },
        { port: PORT, path: "/handler-event", body: { terminalId: TERM, agent: "codex", event: "turn_end" } },
      ]);
    });

    test("after-agent accepts the underscore thread-id spelling", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "after-agent",
        payload: JSON.stringify({ thread_id: "thread-2" }),
      });
      expect(posts[0]?.body).toEqual({ terminalId: TERM, sessionId: "thread-2", agent: "codex" });
    });

    test("permission-request posts a bare notify", async () => {
      expect(await hookPosts({ agent: name, event: "permission-request", stdin: "{}" })).toEqual([
        { port: PORT, path: "/notify", body: { type: "permission_request", terminalId: TERM } },
      ]);
    });

    test("stop forwards last_assistant_message", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "stop",
        stdin: JSON.stringify({ last_assistant_message: "  Refactored the parser  " }),
      });
      expect(posts).toEqual([
        {
          port: PORT,
          path: "/notify",
          body: { type: "task_complete", terminalId: TERM, message: "Refactored the parser" },
        },
      ]);
    });

    test("stop still notifies when the payload is unreadable", async () => {
      // Deliberate parse-failure fallthrough: a turn-end notification must
      // survive a payload we cannot read.
      for (const stdin of ["not json at all", JSON.stringify({ last_assistant_message: null })]) {
        expect(await hookPosts({ agent: name, event: "stop", stdin })).toEqual([
          { port: PORT, path: "/notify", body: { type: "task_complete", terminalId: TERM } },
        ]);
      }
    });

    test("session-start posts the hook-alive trust-drift probe", async () => {
      expect(await hookPosts({ agent: name, event: "session-start", stdin: "{}" })).toEqual([
        { port: PORT, path: "/hook-alive", body: { terminalId: TERM } },
      ]);
    });

    test("session-start posts nothing without a terminal id", async () => {
      expect(
        await hookPosts({
          agent: name,
          event: "session-start",
          stdin: "{}",
          env: { ANTGRID_TERMINAL_ID: undefined },
        }),
      ).toEqual([]);
    });
  });

  describe("cursor-agent (hook name: cursor)", () => {
    const name = HOOK_NAME["cursor-agent"]!;

    test("session-start strips a BOM and posts a title with no transcript path", async () => {
      const posts = await hookPosts({
        agent: name,
        event: "session-start",
        stdin: `\uFEFF${JSON.stringify({ session_id: "cursor-1", transcript_path: "/t" })}`,
      });
      expect(posts).toEqual([
        { port: PORT, path: "/session-title", body: { terminalId: TERM, sessionId: "cursor-1", agent: "cursor" } },
      ]);
    });

    test("stop notifies only for a completed status", async () => {
      expect(
        await hookPosts({ agent: name, event: "stop", stdin: JSON.stringify({ status: "completed" }) }),
      ).toEqual([{ port: PORT, path: "/notify", body: { type: "task_complete", terminalId: TERM } }]);
      expect(
        await hookPosts({ agent: name, event: "stop", stdin: JSON.stringify({ status: "aborted" }) }),
      ).toEqual([]);
    });

    test("cursor never posts a handler event", async () => {
      const posts = [
        ...(await hookPosts({ agent: name, event: "session-start", stdin: JSON.stringify({ session_id: "c" }) })),
        ...(await hookPosts({ agent: name, event: "stop", stdin: JSON.stringify({ status: "completed" }) })),
      ];
      expect(posts.some((p) => p.path === "/handler-event")).toBe(false);
    });
  });

  describe("github-copilot (hook name: github-copilot)", () => {
    const name = HOOK_NAME["github-copilot"]!;

    test("session-start posts a plain title", async () => {
      expect(
        await hookPosts({ agent: name, event: "session-start", stdin: JSON.stringify({ sessionId: "c1" }) }),
      ).toEqual([
        { port: PORT, path: "/session-title", body: { terminalId: TERM, sessionId: "c1", agent: "github-copilot" } },
      ]);
    });

    test("agent-stop marks the title post titleOnly", async () => {
      expect(
        await hookPosts({ agent: name, event: "agent-stop", stdin: JSON.stringify({ sessionId: "c1" }) }),
      ).toEqual([
        {
          port: PORT,
          path: "/session-title",
          body: { terminalId: TERM, sessionId: "c1", agent: "github-copilot", titleOnly: true },
        },
      ]);
    });

    test("all six session-id spellings resolve, in precedence order", async () => {
      const spellings: Array<[unknown, string]> = [
        [{ sessionId: "a" }, "a"],
        [{ session_id: "b" }, "b"],
        [{ session: { id: "c" } }, "c"],
        [{ session: { sessionId: "d" } }, "d"],
        [{ conversationId: "e" }, "e"],
        [{ conversation_id: "f" }, "f"],
        // Precedence: flat camel/snake, then nested, then conversation.
        [{ conversation_id: "last", session: { id: "mid" }, sessionId: "first" }, "first"],
        [{ conversation_id: "last", session: { id: "mid" } }, "mid"],
      ];
      for (const [payload, expected] of spellings) {
        const posts = await hookPosts({
          agent: name,
          event: "session-start",
          stdin: JSON.stringify(payload),
        });
        expect(posts[0]?.body).toMatchObject({ sessionId: expected });
      }
    });

    test("copilot alone falls back to the <abDir>/api.port file", async () => {
      const dir = "C:/Users/test/.antgrid";
      expect(
        await hookPosts({
          agent: name,
          event: "session-start",
          stdin: JSON.stringify({ sessionId: "c1" }),
          env: { ANTGRID_API_PORT: "", ANTGRID_DIR: dir },
          files: { [`${dir}/api.port`]: "43124\n" },
        }),
      ).toEqual([
        { port: 43124, path: "/session-title", body: { terminalId: TERM, sessionId: "c1", agent: "github-copilot" } },
      ]);
      // Every other agent gets no such fallback.
      expect(
        await hookPosts({
          agent: "claude",
          event: "session-start",
          stdin: JSON.stringify({ session_id: "s1" }),
          env: { ANTGRID_API_PORT: "", ANTGRID_DIR: dir },
          files: { [`${dir}/api.port`]: "43124\n" },
        }),
      ).toEqual([]);
    });
  });

  for (const key of AGENT_KEYS.filter((k) => HOOK_NAME[k] === null)) {
    test(`${key} has no hook-runner name and posts nothing`, async () => {
      for (const event of ["session-start", "stop", "after-agent", "agent-stop", "notification"]) {
        expect(await hookPosts({ agent: key, event, stdin: "{}" })).toEqual([]);
      }
    });
  }

  test("opencode's plugin wire name is not a hook-runner name either", async () => {
    for (const event of ["session-start", "stop"]) {
      expect(await hookPosts({ agent: "opencode", event, stdin: "{}" })).toEqual([]);
    }
  });

  test("an out-of-range port drops every post", async () => {
    expect(
      await hookPosts({
        agent: "claude",
        event: "stop",
        stdin: "{}",
        env: { ANTGRID_API_PORT: "70000" },
      }),
    ).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Concern: handler context
//
// The tier<->hint invariant lives here: a transcriptPath comes back only when
// the source is a followable FILE, never synthesized.
// ---------------------------------------------------------------------------

const CODEX_THREAD = "019f8e9e-acc9-78a2-8f61-803e7bbabac3";

function claudeTranscript(texts: string[]): string {
  const path = join(tmp("ab-spec-cl-"), "t.jsonl");
  writeFileSync(path, texts.map((t) => JSON.stringify({ message: { content: t } })).join("\n"), "utf8");
  return path;
}

function codexHome(lines: object[]): string {
  const home = tmp("ab-spec-cx-");
  const dir = join(home, "sessions", "2026", "07", "28");
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, `rollout-x-${CODEX_THREAD}.jsonl`),
    lines.map((l) => JSON.stringify(l)).join("\n"),
    "utf8",
  );
  return home;
}

function opencodeDb(texts: string[]): string {
  const path = join(tmp("ab-spec-oc-"), "opencode.db");
  const db = new Database(path);
  db.exec(`
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
    CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
  `);
  texts.forEach((t, i) => {
    db.query("INSERT INTO message VALUES (?, ?, ?, ?, ?)").run(`msg_${i}`, "ses_1", i, i, JSON.stringify({ role: "user" }));
    db.query("INSERT INTO part VALUES (?, ?, ?, ?, ?, ?)").run(`prt_${i}`, `msg_${i}`, "ses_1", i, i, JSON.stringify({ type: "text", text: t }));
  });
  db.close();
  return path;
}

describe("handler context", () => {
  test("claude-code reads the transcript and echoes its input path", async () => {
    const path = claudeTranscript(["hello"]);
    const c = await assembleContext({
      tool: "claude-code",
      transcriptPath: path,
      recentPty: "ignored",
      purpose: "decide",
    });
    expect(c.source).toBe("transcript");
    expect(c.text).toBe("hello");
    expect(c.transcriptPath).toBe(path);
  });

  test("codex resolves the rollout and returns the path it found", async () => {
    const home = codexHome([{ type: "event_msg", payload: { type: "agent_message", message: "built it" } }]);
    const c = await assembleContext({
      tool: "codex",
      agentSessionId: CODEX_THREAD,
      recentPty: "ignored",
      purpose: "decide",
      codexHome: home,
    });
    expect(c.source).toBe("transcript");
    expect(c.text).toBe("built it");
    expect(c.transcriptPath).toContain(`${CODEX_THREAD}.jsonl`);
  });

  test("codex withholds the path when the rollout exists but yields no messages", async () => {
    const home = codexHome([{ type: "world_state", payload: {} }]);
    const c = await assembleContext({
      tool: "codex",
      agentSessionId: CODEX_THREAD,
      recentPty: "tail",
      purpose: "decide",
      codexHome: home,
    });
    expect(c.source).toBe("pty");
    expect(c.transcriptPath).toBeUndefined();
  });

  test("opencode reads the db and deliberately returns NO transcriptPath", async () => {
    const c = await assembleContext({
      tool: "opencode",
      agentSessionId: "ses_1",
      recentPty: "ignored",
      purpose: "decide",
      opencodeDbPath: opencodeDb(["question", "answer"]),
    });
    expect(c.source).toBe("transcript");
    expect(c.text).toBe("question\n---\nanswer");
    expect(c.transcriptPath).toBeUndefined();
  });

  // The remaining agents have no transcript reader: even handed a real claude
  // transcript, a real codex home and a real opencode db, they fall to PTY.
  for (const key of ["cursor-agent", "github-copilot", "kilo", "kimi", "mistral-vibe"] as const) {
    test(`${key} has no transcript reader and falls back to PTY`, async () => {
      const c = await assembleContext({
        tool: key,
        transcriptPath: claudeTranscript(["hello"]),
        agentSessionId: CODEX_THREAD,
        recentPty: "\x1b[32m$ build ok\x1b[0m",
        purpose: "decide",
        codexHome: codexHome([{ type: "event_msg", payload: { type: "agent_message", message: "built it" } }]),
        opencodeDbPath: opencodeDb(["question"]),
      });
      expect(c.source).toBe("pty");
      expect(c.text).toBe("$ build ok");
      expect(c.transcriptPath).toBeUndefined();
    });
  }
});

// ---------------------------------------------------------------------------
// Concern: update specs
// ---------------------------------------------------------------------------

describe("update specs", () => {
  const expected: PerAgent<{ npmPackage: string; command: string; updateArgs: string[]; readState: boolean } | null> = {
    "claude-code": { npmPackage: "@anthropic-ai/claude-code", command: "claude", updateArgs: ["update"], readState: false },
    codex: { npmPackage: "@openai/codex", command: "codex", updateArgs: ["update"], readState: true },
    opencode: { npmPackage: "opencode-ai", command: "opencode", updateArgs: ["upgrade"], readState: false },
    // IDE-bound, no self-updater: a request fails soft rather than throwing.
    "cursor-agent": null,
    "github-copilot": null,
    kilo: null,
    kimi: null,
    "mistral-vibe": null,
  };

  for (const key of AGENT_KEYS) {
    test(key, () => {
      const spec = updateSpecFor(key);
      const want = expected[key];
      if (!want) {
        expect(spec).toBeNull();
        return;
      }
      // The tool id must round-trip: the SAME string flows detection →
      // agent:updateAvailable → app echo → agent:update → session filter.
      expect(spec?.tool).toBe(key);
      expect(spec?.npmPackage).toBe(want.npmPackage);
      expect(spec?.command).toBe(want.command);
      expect(spec?.updateArgs).toEqual(want.updateArgs);
      expect(typeof spec?.readState).toBe(want.readState ? "function" : "undefined");
    });
  }

  test("an unregistered tool fails soft", () => {
    expect(updateSpecFor("some-future-agent")).toBeNull();
  });
});
